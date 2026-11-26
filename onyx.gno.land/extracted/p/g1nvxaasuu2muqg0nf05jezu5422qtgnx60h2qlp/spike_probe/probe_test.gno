package spike_probe

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestApplyMovesKernelDeterministic(t *testing.T) {
	solved := SolvedState()
	for i, color := range solved {
		uassert.Equal(t, uint8(i/9), color)
	}
	uassert.True(t, ApplyMovesKernel(0) == solved)
	state := ApplyMovesKernel(80)
	uassert.True(t, state == ApplyMovesKernel(80))
	uassert.True(t, state != solved)
}

func TestCommitHashGoldenVectors(t *testing.T) {
	// V1-V3 from fixtures/golden-vectors.json.
	uassert.Equal(t,
		"0531053c3b58a3c1433ff5c7710e5452eb8faef84d292816ae758291ee9a0fe6",
		CommitHash("colorado/v1", "D:20782:wca", "g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp", "R U R' U' F2 L D' B", "a1b2c3d4e5f60718293a4b5c6d7e8f90"),
	)
	uassert.Equal(t,
		"8fce2e46cedb3ba0fc0aea2c007c3d5701580ae4ccb1d6b4f99b90dd25e2cc57",
		CommitHash("colorado/v1", "D:20782:twisted", "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj", "Rw U' F x2 L' D", "00112233445566778899aabbccddeeff"),
	)
	uassert.Equal(t,
		"668f57d5e353bfb85534666f9d2d0e48bd841ed68780f0d5fa295df88a689a44",
		CommitHash("colorado/v1", "Q:1", "g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp", "U R F' L' D B", "deadbeefcafebabe0123456789abcdef"),
	)
}

func TestEscapeJSONStringAllControlChars(t *testing.T) {
	uassert.Equal(t, `a\"b\\c\nd\u0000e\u001ff`, EscapeJSONString("a\"b\\c\nd\x00e\x1ff"))
	controls := "\x00\x01\x02\x03\x04\x05\x06\x07\b\t\n\x0b\f\r\x0e\x0f" +
		"\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"
	want := `\u0000\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f` +
		`\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f`
	uassert.Equal(t, want, EscapeJSONString(controls))
}

func TestRenderNetMarkdownSingleWrap(t *testing.T) {
	md := RenderNetMarkdown(SolvedState(), "Cube Net")
	uassert.True(t, strings.HasPrefix(md, "![Cube Net](data:image/svg+xml"))
	uassert.False(t, strings.Contains(md, "![Cube Net](!["))
}
