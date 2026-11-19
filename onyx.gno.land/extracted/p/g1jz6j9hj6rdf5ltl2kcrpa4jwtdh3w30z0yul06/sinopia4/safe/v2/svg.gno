package safe

import (
	"chain/markdown"
	"errors"
	"strconv"
	"strings"
)

// AssertSVG checks an engine's raw SVG output with a strict allowlist
// (SA-M3; it replaced a substring blacklist that namespace prefixes, URL
// whitespace and CSS escapes could slip past). The document is tokenized
// as XML and must be well formed:
//
//   - only the elements in svgElements, without a namespace prefix: no
//     script, style, foreignObject, image, a, animation (set, animate*) or
//     anything else that can run code, load a resource or redefine the page;
//   - only the attributes in svgAttributeList, without a prefix except
//     xlink:href and the two fixed xmlns declarations; event handlers and
//     style= are therefore impossible;
//   - attribute values hold no control character, backslash, '<', ':' or
//     non-allowlisted entity, so no URL scheme (javascript:, data:, http:)
//     can be spelled, however it is split or escaped; url() must be
//     url(#id) and href must be #id;
//   - (v2, WP-J J-4) no CSS <image> function that takes a URL as a string:
//     no value may contain image(, image-set(, cross-fade( or element(
//     (ASCII case-insensitive, Go lower-casing, so also -webkit-image-set(),
//     İmage(), …), and mask must be exactly "none" or "url(#id)";
//   - no comments, CDATA, doctype, entities or processing instructions.
//
// The frontend shows art only through <img>, which never runs scripts; this
// check is the defence in depth for every other place a data: URI ends up
// (wallets, explorers, indexers; RA M-7, design §5.4).
//
// v2 (mainnet plan §2.1, M-2) accepts exactly the documents v1 accepts,
// except the J-4 rule above, and returns the same error texts, at ~3k
// instead of ~30k gas per byte: one table-driven pass proves ordinary
// tokens clean, and every token it cannot prove clean goes through v1's
// checks unchanged (checkAttr, checkChars), so the first error found is
// v1's; the J-4 checks (checkCSSValue) run on a value only after v1's checks
// passed it. UTF-8 validity is one native MatchCharsetN call for ASCII
// documents, and long d/points values are skipped with native probes.
// Proof: v1's tests, the differential corpus zz_svg_corpus_test.gno (v2 =
// the TypeScript twin; v1 = v2 except on J-4 documents, listed by case) and
// the gas filetests z_svg_gas_*.
func AssertSVG(svg string, maxBytes int) error {
	if len(svg) == 0 {
		return errors.New("svg: empty")
	}
	if len(svg) > maxBytes {
		return errors.New("svg: larger than " + strconv.Itoa(maxBytes) + " bytes")
	}
	if !validUTF8(svg) {
		return errors.New("svg: invalid UTF-8")
	}
	if !strings.HasPrefix(svg, "<svg") || !strings.HasSuffix(svg, "</svg>") {
		return errors.New("svg: must start with <svg and end with </svg>")
	}
	return scanSVG(svg)
}

const (
	svgNS   = "http://www.w3.org/2000/svg"
	xlinkNS = "http://www.w3.org/1999/xlink"
)

// svgElements are the drawing elements an engine may use.
var svgElements = map[string]bool{
	"svg": true, "g": true, "defs": true, "symbol": true, "use": true,
	"title": true, "desc": true,
	"path": true, "rect": true, "circle": true, "ellipse": true,
	"line": true, "polyline": true, "polygon": true,
	"text": true, "tspan": true,
	"linearGradient": true, "radialGradient": true, "stop": true,
	"clipPath": true, "mask": true, "pattern": true,
	"filter": true, "feGaussianBlur": true, "feOffset": true, "feBlend": true,
	"feColorMatrix": true, "feComposite": true, "feFlood": true, "feMerge": true,
	"feMergeNode": true, "feMorphology": true, "feTurbulence": true,
	"feDisplacementMap": true, "feComponentTransfer": true, "feFuncR": true,
	"feFuncG": true, "feFuncB": true, "feFuncA": true,
}

// svgAttributeList holds the geometry, paint and filter attributes (the v1
// set, reordered: the first six have the fixed ids below). Absent on
// purpose: style, on*, src, every animation attribute (attributeName, to,
// from, by, begin), and every prefixed name except xlink:href. An
// attribute's id is its index + 1 (frontend chain/assertSvg.ts uses the
// same list).
var svgAttributeList = []string{
	"xmlns", "xmlns:xlink", "href", "xlink:href", "d", "points",
	"id", "class", "version", "viewBox", "preserveAspectRatio",
	"x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr",
	"width", "height", "pathLength", "transform",
	"fill", "fill-opacity", "fill-rule",
	"stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
	"stroke-linejoin", "stroke-dasharray", "stroke-dashoffset", "stroke-miterlimit",
	"opacity", "color", "visibility", "display",
	"clip-path", "clip-rule", "mask", "filter",
	"shape-rendering", "vector-effect", "paint-order", "mix-blend-mode",
	"font-family", "font-size", "font-weight", "font-style",
	"text-anchor", "dominant-baseline", "letter-spacing",
	"textLength", "lengthAdjust", "dx", "dy", "rotate",
	"gradientUnits", "gradientTransform", "spreadMethod",
	"offset", "stop-color", "stop-opacity",
	"patternUnits", "patternContentUnits", "patternTransform",
	"clipPathUnits", "maskUnits", "maskContentUnits",
	"filterUnits", "primitiveUnits", "result", "in", "in2",
	"stdDeviation", "mode", "type", "values", "operator",
	"k1", "k2", "k3", "k4", "radius",
	"flood-color", "flood-opacity", "baseFrequency", "numOctaves",
	"seed", "stitchTiles", "scale", "xChannelSelector", "yChannelSelector",
	"tableValues", "slope", "intercept", "amplitude", "exponent",
}

const (
	idXmlns = 1 + iota
	idXmlnsXlink
	idHref
	idXlinkHref
	idD
	idPoints
	idMask = 47 // "mask" (J-4: none or url(#id) only); checked in init
)

// svgAttrIDs maps an allowlisted attribute to its id (1..len); 0 = not allowed.
var svgAttrIDs = map[string]int{}

func init() {
	if len(svgAttributeList) > 127 {
		panic("safe: svgAttributeList outgrew the two-word seen mask")
	}
	for i, a := range svgAttributeList {
		svgAttrIDs[a] = i + 1
	}
	if svgAttrIDs["mask"] != idMask {
		panic("safe: idMask is not the id of mask")
	}
}

// Byte classes, generated (256-byte tables indexed by the byte):
//   - textClass: 0 plain, 1 '<', 2 '&', 3 byte >= 0x80, 4 control or DEL
//     (not \t \n \r);
//   - valueClass: 0 plain, 1 '"', 2 '\'', 3 'u', 'U' (url() check) or '('
//     (J-4 function check), 4 '&', 5 byte >= 0x80, 6 '<', '>', ':', '\',
//     control or DEL;
//   - nameFirst / nameRest: XML name characters as v1 reads them (ASCII
//     letters, '_', ':'; then also digits, '-', '.');
//   - spaceClass: ' ', \t, \n, \r.
//
// valuePlainLo/Hi is valueClass 0 as a MatchCharsetN bitmap.
const (
	textClass = "\x04\x04\x04\x04\x04\x04\x04\x04\x04\x00\x00\x04\x04\x00\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03"
	valueClass = "\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x06\x00\x00\x01\x00\x00\x00\x04\x02\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x06\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05\x05"
	nameFirst = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x01\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
	nameRest = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x01\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
	spaceClass = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
	valuePlainLo = 0xabfffe3b00000000
	valuePlainHi = 0x7fdfffffefdfffff
)

func svgErr(msg string) error { return errors.New("svg: " + msg) }

// validUTF8 is utf8.ValidString: an ASCII document passes one native call;
// otherwise s is valid exactly when decoding to runes and re-encoding gives
// s back (an invalid byte decodes to U+FFFD, which re-encodes as EF BF BD,
// never as the byte itself).
func validUTF8(s string) bool {
	if markdown.MatchCharsetN(s, ^uint64(0), ^uint64(0), ^uint64(0), ^uint64(0), 0, len(s)) {
		return true
	}
	return string([]rune(s)) == s
}

// plainRun returns the end of the run of valueClass-0 bytes that starts at
// i, found with native probes (doubling, then bisection); i when the run is
// shorter than the first probe.
func plainRun(s string, i int) int {
	lim := len(s) - i
	lo, hi := 0, 32
	for {
		if hi > lim {
			hi = lim
		}
		if !markdown.MatchCharsetN(s[i:i+hi], valuePlainLo, valuePlainHi, valuePlainLo, valuePlainHi, 0, hi) {
			break
		}
		lo = hi
		if hi == lim {
			return i + lo
		}
		hi *= 2
	}
	if lo == 0 {
		return i
	}
	for hi-lo > 1 {
		mid := (lo + hi) / 2
		if markdown.MatchCharsetN(s[i:i+mid], valuePlainLo, valuePlainHi, valuePlainLo, valuePlainHi, 0, mid) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return i + lo
}

// entityAt reports whether one of the five XML entities starts at s[i]. An
// entity holds no '<' or quote, so matching against the whole document is
// the same as v1's match against the text run or attribute value. The '&'
// lies before the '<' of the final "</svg>", so i+6 <= len(s).
func entityAt(s string, i int) bool {
	switch s[i+1] {
	case 'a':
		return s[i:i+5] == "&amp;" || s[i:i+6] == "&apos;"
	case 'l':
		return s[i:i+4] == "&lt;"
	case 'g':
		return s[i:i+4] == "&gt;"
	case 'q':
		return s[i:i+6] == "&quot;"
	}
	return false
}

// scanSVG is v1's parser as one pass. s starts with "<svg" and ends with
// "</svg>", so every '<' is at most at len(s)-6 and the last byte is '>':
// the table loops stop at one of them and need no bounds check, and no
// token can start inside the final "/svg>" except through its '<'.
func scanSVG(s string) error {
	n := len(s)
	// Every element needs at least 3 bytes ("<g>"), so the depth stays
	// below n/3: the stack never grows (append would copy it).
	stack := make([]string, n/3+1)
	depth := 0
	i := 0
	rootDone := false
	for i < n {
		if rootDone {
			return svgErr("content after the root element")
		}
		if s[i] != '<' {
			// character data: printable characters, whitespace and the
			// five XML entities only (v1 text + checkChars)
			if depth == 0 {
				return svgErr("text outside the root element")
			}
			start := i
			for {
				for textClass[s[i]] == 0 {
					i++
				}
				k := textClass[s[i]]
				if k == 1 {
					break
				}
				if k == 2 && entityAt(s, i) {
					i++
					continue
				}
				if k == 3 && !(s[i] == 0xc2 && s[i+1] < 0xa0) { // not a C1 control
					i++
					continue
				}
				for i < n && s[i] != '<' {
					i++
				}
				if err := checkChars(s[start:i], true); err != nil {
					return err
				}
				break
			}
			continue
		}
		c := s[i+1]
		if c == '!' {
			return svgErr("comments, CDATA, doctype and entity declarations are not allowed")
		}
		if c == '?' {
			return svgErr("processing instructions are not allowed")
		}
		if c == '/' {
			i += 2
			start := i
			if nameFirst[s[i]] != 0 {
				i++
				for nameRest[s[i]] != 0 {
					i++
				}
			}
			name := s[start:i]
			for spaceClass[s[i]] != 0 {
				i++
			}
			if s[i] != '>' {
				return svgErr("malformed closing tag")
			}
			i++
			if depth == 0 || stack[depth-1] != name {
				return svgErr("mismatched closing tag </" + name + ">")
			}
			depth--
			if depth == 0 {
				rootDone = true
			}
			continue
		}
		// open tag
		i++
		start := i
		if nameFirst[s[i]] != 0 {
			i++
			for nameRest[s[i]] != 0 {
				i++
			}
		}
		name := s[start:i]
		if name == "" {
			return svgErr("malformed tag")
		}
		if !svgElements[name] { // no allowed element holds ':'
			return svgErr("element <" + name + "> is not allowed")
		}
		first := depth == 0
		selfClosed := false
		var seenLo, seenHi uint64
		for {
			sp := false
			if spaceClass[s[i]] != 0 {
				sp = true
				i++
				for spaceClass[s[i]] != 0 {
					i++
				}
			}
			c := s[i]
			if c == '>' {
				i++
				stack[depth] = name
				depth++
				break
			}
			if c == '/' {
				if s[i+1] != '>' {
					return svgErr("malformed tag <" + name + ">")
				}
				i += 2
				selfClosed = true
				break
			}
			if !sp {
				return svgErr("attributes must be separated by whitespace in <" + name + ">")
			}
			astart := i
			if nameFirst[s[i]] != 0 {
				i++
				for nameRest[s[i]] != 0 {
					i++
				}
			}
			attr := s[astart:i]
			if attr == "" {
				return svgErr("malformed attribute in <" + name + ">")
			}
			// A name outside the allowlist (id 0) fails after its value is
			// read, as in v1, so it can never be a duplicate.
			id := svgAttrIDs[attr]
			if id > 0 {
				if id < 64 {
					b := uint64(1) << uint(id)
					if seenLo&b != 0 {
						return svgErr("duplicate attribute " + attr)
					}
					seenLo |= b
				} else {
					b := uint64(1) << uint(id-64)
					if seenHi&b != 0 {
						return svgErr("duplicate attribute " + attr)
					}
					seenHi |= b
				}
			}
			for spaceClass[s[i]] != 0 {
				i++
			}
			if s[i] != '=' {
				return svgErr("attribute " + attr + " needs a value")
			}
			i++
			for spaceClass[s[i]] != 0 {
				i++
			}
			q := s[i]
			if q != '"' && q != '\'' {
				return svgErr("attribute " + attr + " must be quoted")
			}
			qk := byte(1)
			if q == '\'' {
				qk = 2
			}
			i++
			vstart := i
			if id == idD || id == idPoints {
				i = plainRun(s, i)
			}
			// mask (J-4) always takes the v1 path, then checkCSSValue
			slow := id == idMask
			chk := 0 // 1: url() check, 2: a CSS image function (J-4)
			for {
				for valueClass[s[i]] == 0 {
					i++
				}
				k := valueClass[s[i]]
				if k == qk {
					break
				}
				if k <= 2 { // the other quote
					i++
					continue
				}
				if k == 3 {
					if s[i] != '(' {
						chk |= 1
					} else if e, p := s[i-1]|0x20, s[i-2]|0x20; ((e == 'e' && (p == 'g' || p == 'd')) ||
						(e == 't' && (p == 'e' || p == 'n'))) && cssImageFuncBefore(s, vstart, i) {
						// prefilter: every word ends in "ge", "de", "et" or "nt"
						// (rotate(, translate(, scale( … never call it)
						chk |= 2
					}
					i++
					continue
				}
				if k == 4 && entityAt(s, i) {
					i++
					continue
				}
				if k == 5 && !(s[i] == 0xc2 && s[i+1] < 0xa0) { // not a C1 control
					i++
					continue
				}
				slow = true
				break
			}
			if slow {
				for i < n && s[i] != q {
					i++
				}
				if i >= n {
					return svgErr("unterminated value of " + attr)
				}
				val := s[vstart:i]
				i++
				if err := checkAttr(name, attr, val); err != nil {
					return err
				}
				if err := checkCSSValue(id, attr, val); err != nil {
					return err
				}
				continue
			}
			// clean value: checkChars and the ':' '\' '<' rule pass
			val := s[vstart:i]
			i++
			if id == 0 {
				return svgErr("attribute " + attr + " is not allowed")
			}
			if id <= idXlinkHref {
				if id == idXmlns {
					return svgErr("xmlns must be " + svgNS) // a clean value holds no ':'
				}
				if id == idXmlnsXlink {
					return svgErr("xmlns:xlink must be " + xlinkNS)
				}
				if !isFragment(val) {
					return svgErr("references must stay inside the document (#id)")
				}
				continue
			}
			if chk != 0 {
				if chk&1 != 0 {
					if err := checkURLRefsLowered(val); err != nil {
						return err
					}
				}
				if chk&2 != 0 {
					return svgErr("attribute " + attr + cssImageFuncErr)
				}
			}
		}
		if first && name != "svg" {
			return svgErr("the root element must be <svg>")
		}
		if selfClosed && depth == 0 {
			rootDone = true
		}
	}
	if depth != 0 {
		return svgErr("unclosed element <" + stack[depth-1] + ">")
	}
	if !rootDone {
		return svgErr("no root element")
	}
	return nil
}

// checkAttr is v1's attribute check, unchanged: allowlist, the two xmlns
// values, characters, ':' '\' '<', href, url().
func checkAttr(elem, attr, val string) error {
	if svgAttrIDs[attr] == 0 {
		return svgErr("attribute " + attr + " is not allowed")
	}
	switch attr {
	case "xmlns":
		if val != svgNS {
			return svgErr("xmlns must be " + svgNS)
		}
		return nil
	case "xmlns:xlink":
		if val != xlinkNS {
			return svgErr("xmlns:xlink must be " + xlinkNS)
		}
		return nil
	}
	if err := checkChars(val, false); err != nil {
		return svgErr("attribute " + attr + ": " + err.Error())
	}
	if strings.ContainsAny(val, ":\\<") {
		return svgErr("attribute " + attr + " contains a forbidden character (':', '\\' or '<')")
	}
	if attr == "href" || attr == "xlink:href" {
		if !isFragment(val) {
			return svgErr("references must stay inside the document (#id)")
		}
		return nil
	}
	return checkURLRefs(val)
}

// checkCSSValue is the J-4 rule (v2 only), run on a value v1's checks
// passed: no CSS function that takes an image URL as a string (a
// protocol-relative or path URL needs no ':' and no url(), and browsers
// fetch it when the SVG is inlined or opened as a document), and mask is
// exactly "none" or "url(#id)" (the one allowlisted attribute whose CSS
// property takes an <image>).
func checkCSSValue(id int, attr, val string) error {
	for i := 0; i < len(val); i++ {
		if val[i] == '(' && cssImageFuncBefore(val, 0, i) {
			return svgErr("attribute " + attr + cssImageFuncErr)
		}
	}
	if id == idMask && val != "none" &&
		!(len(val) >= 7 && val[:5] == "url(#" && val[len(val)-1] == ')' && isFragment(val[4:len(val)-1])) {
		return svgErr("mask must be none or url(#id)")
	}
	return nil
}

const cssImageFuncErr = " uses a CSS image function (image, image-set, cross-fade, element)"

// cssImageFuncs are the CSS functions that take an image URL as a string
// (J-4); with the '(' after them, a value may not contain them.
var cssImageFuncs = []string{"image", "image-set", "cross-fade", "element"}

// cssImageFuncBefore reports whether s[start:p] (p is a '(') ends with one
// of cssImageFuncs after Go's strings.ToLower: ASCII letters fold, and the
// only non-ASCII rune lowering to a letter of these words is U+0130 ('i';
// U+212A lowers to 'k', which none holds). Every other byte compares exactly.
func cssImageFuncBefore(s string, start, p int) bool {
	for _, w := range cssImageFuncs {
		j := p
		k := len(w) - 1
		for ; k >= 0; k-- {
			c := w[k]
			if j > start && (s[j-1] == c || (c >= 'a' && c <= 'z' && s[j-1]|0x20 == c)) {
				j--
				continue
			}
			if c == 'i' && j-1 > start && s[j-2] == 0xc4 && s[j-1] == 0xb0 { // U+0130
				j -= 2
				continue
			}
			break
		}
		if k < 0 {
			return true
		}
	}
	return false
}

// checkURLRefs is v1's url() rule: every url( must hold #id.
func checkURLRefs(val string) error {
	low := strings.ToLower(val)
	for {
		k := strings.Index(low, "url")
		if k < 0 {
			return nil
		}
		rest := strings.TrimLeft(low[k+3:], " ")
		if !strings.HasPrefix(rest, "(") {
			low = low[k+3:]
			continue
		}
		rest = strings.TrimLeft(rest[1:], " ")
		end := strings.IndexByte(rest, ')')
		if end < 0 || !isFragment(strings.TrimRight(rest[:end], " ")) {
			return svgErr("references must stay inside the document (url(#id))")
		}
		low = rest[end:]
	}
}

// checkURLRefsLowered is checkURLRefs without strings.ToLower: it scans val
// once and compares case-insensitively. The url() rule only looks at ASCII
// bytes ("url", '(', ')', ' ', fragment characters); the only non-ASCII
// runes Go's ToLower maps to ASCII are U+0130 (to 'i') and U+212A (to 'k'),
// so fragmentLowered accepts their UTF-8 forms as fragment characters.
// Every other non-ASCII byte fails a match either way. val is valid UTF-8.
func checkURLRefsLowered(val string) error {
	n := len(val)
	p := 0
	for {
		k := -1
		for j := p; j+2 < n; j++ {
			if val[j]|0x20 == 'u' && val[j+1]|0x20 == 'r' && val[j+2]|0x20 == 'l' {
				k = j
				break
			}
		}
		if k < 0 {
			return nil
		}
		r := k + 3
		for r < n && val[r] == ' ' {
			r++
		}
		if r >= n || val[r] != '(' {
			p = k + 3
			continue
		}
		r++
		for r < n && val[r] == ' ' {
			r++
		}
		e := r
		for e < n && val[e] != ')' {
			e++
		}
		if e >= n {
			return svgErr("references must stay inside the document (url(#id))")
		}
		t := e
		for t > r && val[t-1] == ' ' {
			t--
		}
		if !fragmentLowered(val[r:t]) {
			return svgErr("references must stay inside the document (url(#id))")
		}
		p = e
	}
}

// fragmentLowered is isFragment(strings.ToLower(v)) for valid UTF-8 v.
func fragmentLowered(v string) bool {
	if len(v) < 2 || v[0] != '#' {
		return false
	}
	for i := 1; i < len(v); i++ {
		c := v[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' {
			continue
		}
		if c == 0xe2 && i+2 < len(v) && v[i+1] == 0x84 && v[i+2] == 0xaa { // U+212A KELVIN SIGN -> 'k'
			i += 2
			continue
		}
		if c == 0xc4 && i+1 < len(v) && v[i+1] == 0xb0 { // U+0130 -> 'i'
			i++
			continue
		}
		return false
	}
	return true
}

// checkChars allows printable characters and the five XML entities; text
// (character data) may also hold whitespace, attribute values only spaces.
func checkChars(s string, isText bool) error {
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '&':
			ok := false
			for _, e := range []string{"&amp;", "&lt;", "&gt;", "&quot;", "&apos;"} {
				if strings.HasPrefix(s[i:], e) {
					ok = true
					break
				}
			}
			if !ok {
				return svgErr("only &amp; &lt; &gt; &quot; &apos; entities are allowed")
			}
		case c == 0x7f || (c < 0x20 && !(isText && isSpace(c))):
			return svgErr("control characters are not allowed")
		case c == '>' && !isText:
			return svgErr("'>' in an attribute value")
		}
	}
	for _, r := range s {
		if r >= 0x80 && r <= 0x9f {
			return svgErr("control characters are not allowed")
		}
	}
	return nil
}

func isFragment(v string) bool {
	if len(v) < 2 || v[0] != '#' {
		return false
	}
	for i := 1; i < len(v); i++ {
		c := v[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
			return false
		}
	}
	return true
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}
