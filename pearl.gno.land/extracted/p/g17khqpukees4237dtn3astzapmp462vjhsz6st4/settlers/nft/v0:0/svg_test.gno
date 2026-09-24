package nft

import (
	"strconv"
	"strings"
	"testing"
)

// pctDecode decodes a percent-encoded string, the way a browser would for a data URI.
func pctDecode(t *testing.T, s string) string {
	t.Helper()
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			b.WriteByte(s[i])
			continue
		}
		v, err := strconv.ParseUint(s[i+1:i+3], 16, 8)
		assert(t, err == nil, "invalid percent encoding")
		b.WriteByte(byte(v))
		i += 2
	}
	return b.String()
}

func TestRenderSVGPanicsWithInvalidTraits(t *testing.T) {
	for _, tc := range invalidTraits {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			message := panicMessage(func() { RenderSVG(tc.traits, Options{}) })

			// Assert
			assertContains(t, "panic", message, tc.err)
		})
	}
}

func TestRenderSVGWithSize(t *testing.T) {
	// Arrange
	traits := NewTraits("alice")
	plain := RenderSVG(traits, Options{})

	// Act
	got := RenderSVG(traits, Options{Size: 100})

	// Assert
	want := strings.Replace(plain, `viewBox="-4 0 32 32"`, `viewBox="-4 0 32 32" width="100" height="100"`, 1)
	assertEqual(t, got, want, "size 100")
}

func TestRenderSVGWithCanonicalSize(t *testing.T) {
	// Arrange
	traits := NewTraits("alice")

	// Act
	got := RenderSVG(traits, Options{Size: CanonicalSize})

	// Assert
	assertContains(t, "canonical size", got, `width="512" height="512" shape-rendering="crispEdges"`)
}

func TestRenderSVGWithoutBackground(t *testing.T) {
	// Arrange
	traits := NewTraits("alice")
	plain := RenderSVG(traits, Options{})

	// Act
	got := RenderSVG(traits, Options{NoBackground: true})

	// Assert
	want := strings.Replace(plain, `<rect x="-4" width="32" height="32" fill="#dbeed2"/>`, "", 1)
	assertEqual(t, got, want, "no background")
}

func TestRenderSVGWithBackgroundColor(t *testing.T) {
	// Arrange
	traits := NewTraits("alice")
	plain := RenderSVG(traits, Options{})

	// Act
	got := RenderSVG(traits, Options{BackgroundColor: "#Ff00aa"})

	// Assert
	want := strings.Replace(plain, `fill="#dbeed2"/>`, `fill="#Ff00aa"/>`, 1)
	assertEqual(t, got, want, "background color")
}

func TestRenderSVGRejectsInvalidBackgroundColors(t *testing.T) {
	// Arrange
	traits := NewTraits("alice")
	colors := []string{"#fff", "ffffff", "#gggggg", `#00000"`, "#0000000"}

	for _, color := range colors {
		// Act
		message := panicMessage(func() { RenderSVG(traits, Options{BackgroundColor: color}) })

		// Assert
		assertContains(t, color, message, "invalid background color")
	}
}

func TestDataURIIsTheEncodedSVG(t *testing.T) {
	// Arrange
	prefix := "data:image/svg+xml;charset=utf-8,"
	options := []Options{{}, {Size: 96}, {Size: CanonicalSize, NoBackground: true}, {BackgroundColor: "#123abc"}}
	cases := append(append([]goldenCase{}, goldenSeeds...), goldenTraits...)

	for i, c := range cases {
		o := options[i%len(options)]

		// Act
		uri := RenderDataURI(c.traits, o)

		// Assert
		assert(t, strings.HasPrefix(uri, prefix), "data URI prefix")
		body := uri[len(prefix):]
		assert(t, !strings.ContainsAny(body, "<>\"# ()"), "characters that must be encoded")
		assertEqual(t, pctDecode(t, body), RenderSVG(c.traits, o), "decoded data URI")
	}
}

func TestDataURIBase64HasThePrefix(t *testing.T) {
	// Arrange
	svg := RenderSVG(NewTraits("bob"), Options{})

	// Act
	uri := DataURI(svg)

	// Assert
	assert(t, strings.HasPrefix(uri, "data:image/svg+xml;base64,"), "base64 data URI")
}
