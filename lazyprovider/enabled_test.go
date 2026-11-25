package main

import (
	"bytes"
	"testing"

	"github.com/vmihailenco/msgpack/v5"
	"google.golang.org/protobuf/encoding/protowire"
)

func bytesField(num protowire.Number, v []byte) []byte {
	b := protowire.AppendTag(nil, num, protowire.BytesType)
	return protowire.AppendBytes(b, v)
}

func dynamicValue(t *testing.T, m map[string]any) []byte {
	t.Helper()
	var buf bytes.Buffer
	enc := msgpack.NewEncoder(&buf)
	enc.SetSortMapKeys(true)
	if err := enc.Encode(m); err != nil {
		t.Fatal(err)
	}
	return bytesField(1, buf.Bytes())
}

// dynamicKeys lists the map keys of a DynamicValue without decoding values
// (unknown values use an extension type only Terraform knows).
func dynamicKeys(t *testing.T, dv []byte) []string {
	t.Helper()
	var keys []string
	rewriteField(dv, 1, func(mp []byte) []byte {
		dec := msgpack.NewDecoder(bytes.NewReader(mp))
		n, err := dec.DecodeMapLen()
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < n; i++ {
			k, _ := dec.DecodeString()
			if _, err := dec.DecodeRaw(); err != nil {
				t.Fatal(err)
			}
			keys = append(keys, k)
		}
		return mp
	})
	return keys
}

func decodeDynamicValue(t *testing.T, dv []byte) map[string]any {
	t.Helper()
	var out map[string]any
	var mp []byte
	rewriteField(dv, 1, func(b []byte) []byte { mp = b; return b })
	if err := msgpack.Unmarshal(mp, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// Regression: the value handed to the rewrite function aliases the rest of the
// message; appending to it must not overwrite the fields that follow.
func TestRewriteFieldDoesNotClobberFollowingFields(t *testing.T) {
	msg := append(bytesField(1, []byte("inner")), bytesField(2, []byte("after"))...)
	out := rewriteField(msg, 1, func(v []byte) []byte { return append(v, "-grown"...) })
	want := append(bytesField(1, []byte("inner-grown")), bytesField(2, []byte("after"))...)
	if !bytes.Equal(out, want) {
		t.Fatalf("got %q, want %q", out, want)
	}
	if !bytes.Equal(msg, append(bytesField(1, []byte("inner")), bytesField(2, []byte("after"))...)) {
		t.Fatal("rewriteField modified its input")
	}
}

func TestInjectEnabledAddsOptionalBool(t *testing.T) {
	attr := append(bytesField(1, []byte("region")), bytesField(2, []byte(`"string"`))...)
	block := bytesField(2, attr)           // Block.attributes
	schema := bytesField(2, block)         // Schema.block
	resp := append(bytesField(1, schema), // Response.provider
		bytesField(2, []byte("resource schemas stay as they are"))...)

	out, ok := injectEnabled(resp)
	if !ok {
		t.Fatal("expected injection")
	}
	var names []string
	rewriteField(out, 1, func(s []byte) []byte {
		rewriteField(s, 2, func(b []byte) []byte { names = fieldStrings(b, 2, 1); return b })
		return s
	})
	if len(names) != 2 || names[0] != "region" || names[1] != enabledAttr {
		t.Fatalf("attributes = %v", names)
	}
	if !bytes.HasSuffix(out, bytesField(2, []byte("resource schemas stay as they are"))) {
		t.Fatal("fields after the provider schema were changed")
	}
	if _, ok := injectEnabled(out); ok {
		t.Fatal("a provider that already has `enabled` must be left alone")
	}
}

func TestStripEnabledStates(t *testing.T) {
	unknown := []byte{0xd4, 0x00, 0x00} // cty's msgpack encoding of an unknown value
	cases := []struct {
		name  string
		value any
		raw   []byte
		want  enabledState
	}{
		{"true", true, nil, enabledTrue},
		{"false", false, nil, enabledFalse},
		{"null", nil, nil, enabledUnset},
		{"unknown", nil, unknown, enabledUnknown},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dv := dynamicValue(t, map[string]any{"enabled": c.value, "region": "us-east-2"})
			if c.raw != nil { // splice the raw unknown value in place of the null
				dv = rewriteField(dv, 1, func(mp []byte) []byte {
					return bytes.Replace(mp, append([]byte{0xa7}, append([]byte("enabled"), 0xc0)...), append(append([]byte{0xa7}, []byte("enabled")...), c.raw...), 1)
				})
			}
			out, state, raw := stripEnabled(dv)
			if state != c.want {
				t.Fatalf("state = %v, want %v", state, c.want)
			}
			got := decodeDynamicValue(t, out)
			if _, present := got["enabled"]; present || got["region"] != "us-east-2" {
				t.Fatalf("stripped config = %v", got)
			}
			keys := dynamicKeys(t, restoreEnabled(out, raw))
			if len(keys) != 2 || keys[1] != "enabled" {
				t.Fatalf("restoreEnabled keys = %v", keys)
			}
		})
	}
}

func TestDiagnosticsDetectsErrors(t *testing.T) {
	warn := append(protowire.AppendVarint(protowire.AppendTag(nil, 1, protowire.VarintType), 2), bytesField(2, []byte("heads up"))...)
	errDiag := diagnostic("broken credentials", "detail")
	resp := append(bytesField(1, warn), bytesField(1, errDiag)...)

	diags, failed := diagnostics(resp)
	if len(diags) != 2 || !failed {
		t.Fatalf("diags=%d failed=%v", len(diags), failed)
	}
	if got := firstSummary(flatten(diags)); got != "broken credentials" {
		t.Fatalf("firstSummary = %q", got)
	}
	if _, failed := diagnostics(bytesField(1, warn)); failed {
		t.Fatal("warnings alone are not a failure")
	}
}
