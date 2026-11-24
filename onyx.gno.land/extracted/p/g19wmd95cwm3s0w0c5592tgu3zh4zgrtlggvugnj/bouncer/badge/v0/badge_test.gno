package badge

import (
	"encoding/base64"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestSVG(t *testing.T) {
	s := SVG("bouncer", "A 96", Green)
	uassert.True(t, strings.HasPrefix(s, `<svg xmlns="http://www.w3.org/2000/svg" width="`))
	uassert.True(t, strings.HasSuffix(s, `</svg>`))
	uassert.True(t, strings.Contains(s, `aria-label="bouncer: A 96"`))
	uassert.True(t, strings.Contains(s, `fill="#2e7d32"`))
	uassert.True(t, strings.Contains(s, `>A 96</text>`))
	// width = (7*7+16) + (4*7+16) = 65 + 44
	uassert.True(t, strings.Contains(s, `width="109" height="20"`))
}

func TestSVGEscapesAndClips(t *testing.T) {
	s := SVG(`<script>"x"&'`, strings.Repeat("é", 100)+"\x00\n", "javascript:red")
	uassert.False(t, strings.Contains(s, "<script>"))
	uassert.True(t, strings.Contains(s, "&lt;script&gt;&quot;x&quot;&amp;&#39;"))
	uassert.True(t, strings.Contains(s, ">"+strings.Repeat("é", maxText)+"</text>"))
	uassert.False(t, strings.Contains(s, "\x00"))
	uassert.True(t, strings.Contains(s, `fill="#616161"`)) // unknown color is grey
}

func TestDataURIAndMarkdown(t *testing.T) {
	s := SVG("bouncer", "F 20", Red)
	uri := DataURI(s)
	urequire.True(t, strings.HasPrefix(uri, "data:image/svg+xml;base64,"))
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(uri, "data:image/svg+xml;base64,"))
	urequire.NoError(t, err)
	uassert.Equal(t, s, string(raw))

	uassert.Equal(t, "!["+`bouncer \[F\] 20`+"]("+uri+")", Markdown("bouncer [F] 20", s, ""))
	uassert.Equal(t, "[![x]("+uri+")](/r/demo/x)", Markdown("x", s, "/r/demo/x"))
}

func TestAltClip(t *testing.T) {
	long := strings.Repeat("a", 200)
	md := Markdown(long, SVG("b", "c", Green), "")
	uassert.True(t, strings.HasPrefix(md, "!["+strings.Repeat("a", maxAlt)+"]("))
}
