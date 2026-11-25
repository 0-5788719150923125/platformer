// lazyprovider: a Terraform provider that stands in front of a real provider
// and defers its setup ("Configure") until the first call that needs it.
//
// Terraform sets up every provider the configuration mentions, even when no
// resource will ever use it (e.g. modules with count = 0). For providers that
// need credentials during setup, that forces every user to hold credentials for
// every cloud a configuration supports. This proxy relays every call to the real
// provider unchanged, except setup: it records Terraform's setup request,
// answers "OK", and forwards the recorded request to the real provider just
// before the first call that needs a configured provider (planning, reading,
// applying, importing, data sources, ephemeral resources). A workspace that
// never uses the provider never sets it up.
//
// Messages are relayed as raw bytes; nothing is decoded except the setup
// response, whose diagnostics are passed through if setup fails.
package main

import (
	"context"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/go-plugin"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// Terraform's plugin handshake (hashicorp/terraform internal/plugin/serve.go).
var handshake = plugin.HandshakeConfig{
	MagicCookieKey:   "TF_PLUGIN_MAGIC_COOKIE",
	MagicCookieValue: "d602bf8f470bc67ca7faa0386276bbdd4330efaf76d1a219cb4d6991ca9872b2",
}

// Real providers behind each proxy type (the proxy's own type comes from its
// binary name, terraform-provider-<type>_v<version>).
var upstreams = map[string]string{
	"aws":     "hashicorp/aws",
	"azurerm": "hashicorp/azurerm",
	"google":  "hashicorp/google",
	"oci":     "oracle/oci",
	"port":    "port-labs/port-labs",
}

// Calls that need a configured provider, and the field number of
// `diagnostics` in each one's response (tfplugin5/6, same numbering).
// 0 = streaming response: a failed setup is reported as an RPC error instead.
var needsSetup = map[string]protowire.Number{
	"ReadResource":           2,
	"PlanResourceChange":     4,
	"ApplyResourceChange":    3,
	"ImportResourceState":    2,
	"ReadDataSource":         2,
	"GenerateResourceConfig": 2,
	"OpenEphemeralResource":  1,
	"RenewEphemeralResource": 1,
	"CloseEphemeralResource": 1,
	"PlanAction":             1,
	"InvokeAction":           0,
	"ListResource":           0,
}

// frame carries a message as raw bytes.
type frame struct{ data []byte }

// codec passes frames through untouched and handles go-plugin's own (typed)
// services normally.
type codec struct{}

func (codec) Marshal(v any) ([]byte, error) {
	if f, ok := v.(*frame); ok {
		return f.data, nil
	}
	return proto.Marshal(v.(proto.Message))
}

func (codec) Unmarshal(data []byte, v any) error {
	if f, ok := v.(*frame); ok {
		f.data = append([]byte(nil), data...)
		return nil
	}
	return proto.Unmarshal(data, v.(proto.Message))
}

func (codec) Name() string { return "proto" }

type rawPlugin struct{ plugin.NetRPCUnsupportedPlugin }

func (rawPlugin) GRPCServer(*plugin.GRPCBroker, *grpc.Server) error { return nil }
func (rawPlugin) GRPCClient(_ context.Context, _ *plugin.GRPCBroker, c *grpc.ClientConn) (any, error) {
	return c, nil
}

type proxy struct {
	service   string // "tfplugin5.Provider" or "tfplugin6.Provider"
	configure string // "Configure" (v5) or "ConfigureProvider" (v6)
	schema    string // "GetSchema" (v5) or "GetProviderSchema" (v6)
	validate  string // "PrepareProviderConfig" (v5) or "ValidateProviderConfig" (v6)
	typ       string // proxy type, e.g. "aws" (for messages)
	conn      *grpc.ClientConn
	log       hclog.Logger
	injected  bool // the provider block accepts `enabled`

	mu          sync.Mutex
	setupReq    []byte
	haveSetup   bool
	configured  bool
	setupErr    error
	setupDiags  [][]byte
	setupFailed bool
	warned      bool
	disabled    bool // enabled = false
	reported    bool // a setup/disabled error has been returned once (later ones are short)
}

// ensureConfigured sends Terraform's recorded setup request to the real
// provider, once, and remembers the outcome.
func (p *proxy) ensureConfigured(ctx context.Context) ([][]byte, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.configured || !p.haveSetup {
		return p.setupDiags, p.setupFailed, p.setupErr
	}
	p.configured = true
	p.log.Debug("first use: configuring the real provider")
	resp := &frame{}
	if err := p.conn.Invoke(context.WithoutCancel(ctx), "/"+p.service+"/"+p.configure, &frame{data: p.setupReq}, resp, grpc.ForceCodec(codec{})); err != nil {
		p.setupErr = err
		return nil, false, err
	}
	p.setupDiags, p.setupFailed = diagnostics(resp.data)
	return p.setupDiags, p.setupFailed, nil
}

// diagnostics returns the raw Diagnostic messages in a setup response (field 1)
// and whether any has severity ERROR (Diagnostic field 1 == 1).
func diagnostics(msg []byte) ([][]byte, bool) {
	var out [][]byte
	failed := false
	for len(msg) > 0 {
		num, typ, n := protowire.ConsumeTag(msg)
		if n < 0 {
			break
		}
		msg = msg[n:]
		if num == 1 && typ == protowire.BytesType {
			d, m := protowire.ConsumeBytes(msg)
			if m < 0 {
				break
			}
			out = append(out, d)
			if severity(d) == 1 {
				failed = true
			}
			msg = msg[m:]
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, msg)
		if m < 0 {
			break
		}
		msg = msg[m:]
	}
	return out, failed
}

func severity(diag []byte) uint64 {
	for len(diag) > 0 {
		num, typ, n := protowire.ConsumeTag(diag)
		if n < 0 {
			return 0
		}
		diag = diag[n:]
		if num == 1 && typ == protowire.VarintType {
			v, _ := protowire.ConsumeVarint(diag)
			return v
		}
		m := protowire.ConsumeFieldValue(num, typ, diag)
		if m < 0 {
			return 0
		}
		diag = diag[m:]
	}
	return 0
}

func (p *proxy) handle(_ any, ss grpc.ServerStream) error {
	full, _ := grpc.MethodFromServerStream(ss)
	name := full[strings.LastIndex(full, "/")+1:]

	switch name {
	case p.schema:
		return p.forwardUnary(ss, full, nil, func(resp []byte) []byte {
			out, ok := injectEnabled(resp)
			p.mu.Lock()
			p.injected = p.injected || ok
			p.mu.Unlock()
			if !ok {
				p.log.Warn("provider already has an `enabled` argument; proxy runs without its own")
			}
			return out
		})
	case p.validate:
		var raw []byte
		return p.forwardUnary(ss, full, func(req []byte) []byte {
			return rewriteField(req, 1, func(dv []byte) []byte {
				out, _, r := stripEnabled(dv)
				raw = r
				return out
			})
		}, func(resp []byte) []byte {
			if p.validate != "PrepareProviderConfig" { // protocol 5 echoes a prepared config back
				return resp
			}
			return rewriteField(resp, 1, func(dv []byte) []byte { return restoreEnabled(dv, raw) })
		})
	case p.configure:
		req := &frame{}
		if err := ss.RecvMsg(req); err != nil {
			return err
		}
		var state enabledState
		req.data = rewriteField(req.data, 2, func(dv []byte) []byte {
			out, st, _ := stripEnabled(dv)
			state = st
			return out
		})
		p.mu.Lock()
		p.setupReq, p.haveSetup = req.data, true
		switch state {
		case enabledFalse:
			p.disabled = true
			p.mu.Unlock()
			return ss.SendMsg(&frame{data: []byte{}})
		case enabledUnknown:
			p.mu.Unlock()
			return ss.SendMsg(&frame{data: []byte{}}) // set up on first use
		}
		// enabled = true or unset: set up now, so errors land on the provider block
		p.configured = true
		p.mu.Unlock()
		resp := &frame{}
		if err := p.conn.Invoke(context.WithoutCancel(ss.Context()), full, req, resp, grpc.ForceCodec(codec{})); err != nil {
			return err
		}
		p.mu.Lock()
		p.setupDiags, p.setupFailed = diagnostics(resp.data)
		p.warned = true // warnings already went out with this response
		p.mu.Unlock()
		return ss.SendMsg(resp)
	}

	if field, ok := needsSetup[name]; ok {
		p.mu.Lock()
		disabled := p.disabled
		p.mu.Unlock()
		if disabled {
			return p.refuse(ss, field, []byte(nil), fmt.Sprintf("The %s provider is disabled in this workspace", p.typ),
				fmt.Sprintf("Its provider block sets enabled = false, so it was never set up, but this resource needs it. Enable %s for this workspace, or remove the resource.", p.typ))
		}
		diags, failed, err := p.ensureConfigured(ss.Context())
		if err != nil {
			return err
		}
		if failed {
			return p.refuse(ss, field, flatten(diags), "", "")
		}
		if len(diags) > 0 && field != 0 && p.takeWarnings() {
			return p.forwardWithDiagnostics(ss, full, field, diags)
		}
	}
	return p.forward(ss, full)
}

// refuse answers a call that can't run: the full diagnostics (or summary and
// detail) the first time, one short line on every later call.
func (p *proxy) refuse(ss grpc.ServerStream, field protowire.Number, full []byte, summary, detail string) error {
	req := &frame{}
	_ = ss.RecvMsg(req)
	p.mu.Lock()
	first := !p.reported
	p.reported = true
	p.mu.Unlock()
	var diags []byte
	switch {
	case first && full != nil:
		diags = full
	case first:
		diags = encodeDiags(field, [][]byte{diagnostic(summary, detail)})
	case summary != "":
		diags = encodeDiags(field, [][]byte{diagnostic(summary, "")})
	default:
		diags = encodeDiags(field, [][]byte{diagnostic(fmt.Sprintf("The %s provider couldn't be set up: %s", p.typ, firstSummary(full)), "")})
	}
	if field == 0 {
		return status.Error(codes.FailedPrecondition, fmt.Sprintf("%s provider unavailable", p.typ))
	}
	if first && full != nil {
		diags = encodeDiags(field, splitDiags(full))
	}
	return ss.SendMsg(&frame{data: diags})
}

// firstSummary is the summary (field 2) of the first error diagnostic, shortened.
func firstSummary(flat []byte) string {
	for _, d := range splitDiags(flat) {
		if severity(d) != 1 {
			continue
		}
		for len(d) > 0 {
			n, t, l := protowire.ConsumeTag(d)
			if l < 0 {
				break
			}
			vl := protowire.ConsumeFieldValue(n, t, d[l:])
			if vl < 0 {
				break
			}
			if n == 2 && t == protowire.BytesType {
				v, _ := protowire.ConsumeBytes(d[l:])
				if len(v) > 160 {
					return string(v[:160]) + "..."
				}
				return string(v)
			}
			d = d[l+vl:]
		}
	}
	return "see the full error on another resource"
}

func encodeDiags(field protowire.Number, diags [][]byte) []byte {
	var out []byte
	for _, d := range diags {
		out = protowire.AppendTag(out, field, protowire.BytesType)
		out = protowire.AppendBytes(out, d)
	}
	return out
}

// flatten/splitDiags carry a list of raw diagnostics through one []byte.
func flatten(diags [][]byte) []byte {
	var out []byte
	for _, d := range diags {
		out = protowire.AppendBytes(out, d)
	}
	if out == nil {
		out = []byte{}
	}
	return out
}

func splitDiags(b []byte) [][]byte {
	var out [][]byte
	for len(b) > 0 {
		d, n := protowire.ConsumeBytes(b)
		if n < 0 {
			break
		}
		out = append(out, d)
		b = b[n:]
	}
	return out
}

// forwardUnary relays one unary call, optionally transforming the request and
// the response bytes.
func (p *proxy) forwardUnary(ss grpc.ServerStream, method string, reqFn, respFn func([]byte) []byte) error {
	req, resp := &frame{}, &frame{}
	if err := ss.RecvMsg(req); err != nil {
		return err
	}
	if reqFn != nil {
		req.data = reqFn(req.data)
	}
	ctx := ss.Context()
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		ctx = metadata.NewOutgoingContext(ctx, md.Copy())
	}
	if err := p.conn.Invoke(ctx, method, req, resp, grpc.ForceCodec(codec{})); err != nil {
		return err
	}
	if respFn != nil {
		resp.data = respFn(resp.data)
	}
	return ss.SendMsg(resp)
}

func (p *proxy) takeWarnings() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.warned {
		return false
	}
	p.warned = true
	return true
}

// forwardWithDiagnostics relays one unary call and appends the given
// diagnostics to its response (repeated fields can be appended as-is).
func (p *proxy) forwardWithDiagnostics(ss grpc.ServerStream, method string, field protowire.Number, diags [][]byte) error {
	req, resp := &frame{}, &frame{}
	if err := ss.RecvMsg(req); err != nil {
		return err
	}
	ctx := ss.Context()
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		ctx = metadata.NewOutgoingContext(ctx, md.Copy())
	}
	if err := p.conn.Invoke(ctx, method, req, resp, grpc.ForceCodec(codec{})); err != nil {
		return err
	}
	for _, d := range diags {
		resp.data = protowire.AppendTag(resp.data, field, protowire.BytesType)
		resp.data = protowire.AppendBytes(resp.data, d)
	}
	return ss.SendMsg(resp)
}

// forward relays one call (unary or streaming) to the real provider.
func (p *proxy) forward(ss grpc.ServerStream, method string) error {
	ctx, cancel := context.WithCancel(ss.Context())
	defer cancel()
	if md, ok := metadata.FromIncomingContext(ss.Context()); ok {
		ctx = metadata.NewOutgoingContext(ctx, md.Copy())
	}
	cs, err := p.conn.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true, ClientStreams: true}, method, grpc.ForceCodec(codec{}))
	if err != nil {
		return err
	}
	go func() {
		for {
			f := &frame{}
			if err := ss.RecvMsg(f); err != nil {
				_ = cs.CloseSend()
				return
			}
			if err := cs.SendMsg(f); err != nil {
				return
			}
		}
	}()
	for {
		f := &frame{}
		err := cs.RecvMsg(f)
		if err == io.EOF {
			ss.SetTrailer(cs.Trailer())
			return nil
		}
		if err != nil {
			return err
		}
		if err := ss.SendMsg(f); err != nil {
			return err
		}
	}
}

// upstreamBinary finds the real provider that `terraform init` installed.
func upstreamBinary(log hclog.Logger) (string, error) {
	if path := os.Getenv("PLATFORMER_LAZY_UPSTREAM"); path != "" {
		return path, nil
	}
	typ := proxyType()
	src, ok := upstreams[typ]
	if !ok {
		return "", fmt.Errorf("no upstream provider known for %q", typ)
	}
	ns, name, _ := strings.Cut(src, "/")
	rel := filepath.Join("providers", "registry.terraform.io", ns, name, "*", runtime.GOOS+"_"+runtime.GOARCH, "terraform-provider-"+name+"*")
	var dirs []string
	if dataDir := os.Getenv("TF_DATA_DIR"); dataDir != "" {
		dirs = append(dirs, dataDir)
	}
	// This directory's .terraform first, then each parent's: `terraform test`
	// inside a module of a repository uses the providers its root installed.
	if wd, err := os.Getwd(); err == nil {
		for dir := wd; ; dir = filepath.Dir(dir) {
			dirs = append(dirs, filepath.Join(dir, ".terraform"))
			if filepath.Dir(dir) == dir {
				break
			}
		}
	}
	var matches []string
	pattern := filepath.Join(".terraform", rel)
	for _, d := range dirs {
		if matches, _ = filepath.Glob(filepath.Join(d, rel)); len(matches) > 0 {
			break
		}
	}
	if len(matches) == 0 {
		return "", fmt.Errorf("real provider %s isn't installed (looked for %s); add it to required_providers under another name, e.g. %s-upstream = { source = %q }", src, pattern, typ, src)
	}
	sort.Slice(matches, func(i, j int) bool { return versionLess(matches[i], matches[j]) })
	log.Debug("upstream", "path", matches[len(matches)-1])
	return matches[len(matches)-1], nil
}

// proxyType is the provider type this binary stands in for, from its name
// (terraform-provider-<type>_v<version>).
func proxyType() string {
	typ := strings.TrimPrefix(filepath.Base(os.Args[0]), "terraform-provider-")
	if i := strings.Index(typ, "_v"); i >= 0 {
		typ = typ[:i]
	}
	return typ
}

func versionLess(a, b string) bool {
	va := strings.Split(filepath.Base(filepath.Dir(filepath.Dir(a))), ".")
	vb := strings.Split(filepath.Base(filepath.Dir(filepath.Dir(b))), ".")
	for i := 0; i < len(va) && i < len(vb); i++ {
		x, _ := strconv.Atoi(va[i])
		y, _ := strconv.Atoi(vb[i])
		if x != y {
			return x < y
		}
	}
	return len(va) < len(vb)
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "-types" { // for scripts/build-providers.sh
		types := make([]string, 0, len(upstreams))
		for t := range upstreams {
			types = append(types, t)
		}
		sort.Strings(types)
		fmt.Println(strings.Join(types, " "))
		return
	}
	log := hclog.New(&hclog.LoggerOptions{Name: "lazyprovider", Output: os.Stderr, Level: hclog.LevelFromString(os.Getenv("TF_LOG"))})

	path, err := upstreamBinary(log)
	if err != nil {
		fmt.Fprintln(os.Stderr, "lazyprovider:", err)
		os.Exit(1)
	}

	// Start the real provider with a clean plugin environment (Terraform's
	// handshake variables are for us, not for it).
	cmd := exec.Command(path)
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "PLUGIN_") && !strings.HasPrefix(kv, handshake.MagicCookieKey+"=") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	set := plugin.PluginSet{"provider": rawPlugin{}}
	client := plugin.NewClient(&plugin.ClientConfig{
		HandshakeConfig:  handshake,
		VersionedPlugins: map[int]plugin.PluginSet{5: set, 6: set},
		Cmd:              cmd,
		AllowedProtocols: []plugin.Protocol{plugin.ProtocolGRPC},
		AutoMTLS:         true,
		Managed:          true,
		Logger:           log,
	})
	defer plugin.CleanupClients()
	rpc, err := client.Client()
	if err != nil {
		fmt.Fprintln(os.Stderr, "lazyprovider: starting", path+":", err)
		os.Exit(1)
	}
	raw, err := rpc.Dispense("provider")
	if err != nil {
		fmt.Fprintln(os.Stderr, "lazyprovider:", err)
		os.Exit(1)
	}
	version := client.NegotiatedVersion()
	p := &proxy{
		service:   fmt.Sprintf("tfplugin%d.Provider", version),
		configure: map[int]string{5: "Configure", 6: "ConfigureProvider"}[version],
		schema:    map[int]string{5: "GetSchema", 6: "GetProviderSchema"}[version],
		validate:  map[int]string{5: "PrepareProviderConfig", 6: "ValidateProviderConfig"}[version],
		typ:       proxyType(),
		conn:      raw.(*grpc.ClientConn),
		log:       log,
	}

	// Serve Terraform with the same protocol version as the real provider.
	hs := handshake
	hs.ProtocolVersion = uint(version)
	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig:  hs,
		VersionedPlugins: map[int]plugin.PluginSet{version: set},
		GRPCServer: func(opts []grpc.ServerOption) *grpc.Server {
			opts = append(opts, grpc.UnknownServiceHandler(p.handle), grpc.ForceServerCodec(codec{}),
				grpc.MaxRecvMsgSize(math.MaxInt32), grpc.MaxSendMsgSize(math.MaxInt32))
			return grpc.NewServer(opts...)
		},
		Logger: log,
	})
}
