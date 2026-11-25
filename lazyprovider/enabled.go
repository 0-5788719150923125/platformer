package main

// The proxy's own provider argument, `enabled`: added to the provider's schema
// and stripped from every config before the real provider sees it.
//
//   enabled = true  (or unset): set the real provider up during Configure, so
//                    setup errors appear once, at the provider block, exactly
//                    as without the proxy.
//   enabled = false: never set it up. Calls that need it fail with one short
//                    diagnostic each, at the resource that needed it.
//   unknown:         set it up on first use (the value isn't known yet).

import (
	"bytes"

	"github.com/vmihailenco/msgpack/v5"
	"google.golang.org/protobuf/encoding/protowire"
)

const enabledAttr = "enabled"

type enabledState int

const (
	enabledUnset enabledState = iota
	enabledTrue
	enabledFalse
	enabledUnknown
)

// rewriteField replaces the value of the first length-delimited field `num`
// (appending it if absent) with f(old value), copying everything else as-is.
func rewriteField(msg []byte, num protowire.Number, f func([]byte) []byte) []byte {
	var out []byte
	done := false
	for len(msg) > 0 {
		n, typ, l := protowire.ConsumeTag(msg)
		if l < 0 {
			return append(out, msg...)
		}
		valLen := protowire.ConsumeFieldValue(n, typ, msg[l:])
		if valLen < 0 {
			return append(out, msg...)
		}
		if n == num && typ == protowire.BytesType && !done {
			v, _ := protowire.ConsumeBytes(msg[l:])
			out = protowire.AppendTag(out, num, protowire.BytesType)
			// Cap the slice: v aliases the rest of msg, and an append inside f
			// would otherwise overwrite the bytes that follow it.
			out = protowire.AppendBytes(out, f(v[:len(v):len(v)]))
			done = true
		} else {
			out = append(out, msg[:l+valLen]...)
		}
		msg = msg[l+valLen:]
	}
	if !done {
		out = protowire.AppendTag(out, num, protowire.BytesType)
		out = protowire.AppendBytes(out, f(nil))
	}
	return out
}

// fieldStrings returns the string values of field `num` in each submessage
// stored under `outer` (e.g. attribute names in a Block).
func fieldStrings(msg []byte, outer, num protowire.Number) []string {
	var names []string
	for len(msg) > 0 {
		n, typ, l := protowire.ConsumeTag(msg)
		if l < 0 {
			break
		}
		vl := protowire.ConsumeFieldValue(n, typ, msg[l:])
		if vl < 0 {
			break
		}
		if n == outer && typ == protowire.BytesType {
			sub, _ := protowire.ConsumeBytes(msg[l:])
			for len(sub) > 0 {
				sn, st, sl := protowire.ConsumeTag(sub)
				if sl < 0 {
					break
				}
				svl := protowire.ConsumeFieldValue(sn, st, sub[sl:])
				if svl < 0 {
					break
				}
				if sn == num && st == protowire.BytesType {
					s, _ := protowire.ConsumeBytes(sub[sl:])
					names = append(names, string(s))
				}
				sub = sub[sl+svl:]
			}
		}
		msg = msg[l+vl:]
	}
	return names
}

// injectEnabled adds `enabled` (optional bool) to the provider block in a
// GetSchema / GetProviderSchema response: Response.provider(1) -> Schema.block(2)
// -> Block.attributes(2). Returns ok=false if the provider already has one.
func injectEnabled(resp []byte) ([]byte, bool) {
	clash := false
	out := rewriteField(resp, 1, func(schema []byte) []byte {
		return rewriteField(schema, 2, func(block []byte) []byte {
			for _, name := range fieldStrings(block, 2, 1) {
				if name == enabledAttr {
					clash = true
					return block
				}
			}
			var attr []byte
			attr = protowire.AppendTag(attr, 1, protowire.BytesType)
			attr = protowire.AppendString(attr, enabledAttr)
			attr = protowire.AppendTag(attr, 2, protowire.BytesType)
			attr = protowire.AppendString(attr, `"bool"`)
			attr = protowire.AppendTag(attr, 3, protowire.BytesType)
			attr = protowire.AppendString(attr, "Platformer lazy provider: false = this workspace doesn't use this provider, so it is never set up (no credentials needed). true or unset = set up as usual.")
			attr = protowire.AppendTag(attr, 5, protowire.VarintType)
			attr = protowire.AppendVarint(attr, 1) // optional
			block = protowire.AppendTag(block, 2, protowire.BytesType)
			return protowire.AppendBytes(block, attr)
		})
	})
	if clash {
		return resp, false
	}
	return out, true
}

// stripEnabled removes `enabled` from a DynamicValue (msgpack map in field 1)
// and reports its value; raw is the encoded value, for putting it back.
func stripEnabled(dv []byte) (out []byte, state enabledState, raw []byte) {
	state = enabledUnset
	out = rewriteField(dv, 1, func(mp []byte) []byte {
		dec := msgpack.NewDecoder(bytes.NewReader(mp))
		n, err := dec.DecodeMapLen()
		if err != nil || n < 0 {
			return mp
		}
		type kv struct {
			k string
			v msgpack.RawMessage
		}
		var kept []kv
		for i := 0; i < n; i++ {
			k, err := dec.DecodeString()
			if err != nil {
				return mp
			}
			v, err := dec.DecodeRaw()
			if err != nil {
				return mp
			}
			if k == enabledAttr {
				raw = append([]byte(nil), v...)
				var b any
				switch err := msgpack.Unmarshal(v, &b); {
				case err != nil:
					state = enabledUnknown // cty encodes unknown values as an extension type
				case b == nil:
					state = enabledUnset
				case b == true:
					state = enabledTrue
				case b == false:
					state = enabledFalse
				default:
					state = enabledUnknown
				}
				continue
			}
			kept = append(kept, kv{k, v})
		}
		var buf bytes.Buffer
		enc := msgpack.NewEncoder(&buf)
		_ = enc.EncodeMapLen(len(kept))
		for _, e := range kept {
			_ = enc.EncodeString(e.k)
			_ = enc.Encode(e.v)
		}
		return buf.Bytes()
	})
	return out, state, raw
}

// restoreEnabled puts `enabled` back into a DynamicValue's msgpack map (for the
// prepared config the real provider returns from validation, protocol 5).
func restoreEnabled(dv, raw []byte) []byte {
	if raw == nil {
		return dv
	}
	return rewriteField(dv, 1, func(mp []byte) []byte {
		dec := msgpack.NewDecoder(bytes.NewReader(mp))
		n, err := dec.DecodeMapLen()
		if err != nil || n < 0 {
			return mp
		}
		var buf bytes.Buffer
		enc := msgpack.NewEncoder(&buf)
		_ = enc.EncodeMapLen(n + 1)
		for i := 0; i < n; i++ {
			k, err := dec.DecodeString()
			if err != nil {
				return mp
			}
			v, err := dec.DecodeRaw()
			if err != nil {
				return mp
			}
			_ = enc.EncodeString(k)
			_ = enc.Encode(v)
		}
		_ = enc.EncodeString(enabledAttr)
		_ = enc.Encode(msgpack.RawMessage(raw))
		return buf.Bytes()
	})
}

// diagnostic builds one Diagnostic message (severity ERROR).
func diagnostic(summary, detail string) []byte {
	var d []byte
	d = protowire.AppendTag(d, 1, protowire.VarintType)
	d = protowire.AppendVarint(d, 1)
	d = protowire.AppendTag(d, 2, protowire.BytesType)
	d = protowire.AppendString(d, summary)
	if detail != "" {
		d = protowire.AppendTag(d, 3, protowire.BytesType)
		d = protowire.AppendString(d, detail)
	}
	return d
}
