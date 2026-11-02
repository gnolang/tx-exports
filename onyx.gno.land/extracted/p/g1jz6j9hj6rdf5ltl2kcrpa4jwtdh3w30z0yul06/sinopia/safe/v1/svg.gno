package safe

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// AssertSVG checks an engine's raw SVG output with a strict allowlist
// (SA-M3; it replaced a substring blacklist that namespace prefixes, URL
// whitespace and CSS escapes could slip past). The document is tokenized
// as XML and must be well formed:
//
//   - only the elements in svgElements, without a namespace prefix: no
//     script, style, foreignObject, image, a, animation (set, animate*) or
//     anything else that can run code, load a resource or redefine the page;
//   - only the attributes in svgAttributes, without a prefix except
//     xlink:href and the two fixed xmlns declarations; event handlers and
//     style= are therefore impossible;
//   - attribute values hold no control character, backslash, '<', ':' or
//     non-allowlisted entity, so no URL scheme (javascript:, data:, http:)
//     can be spelled, however it is split or escaped; url() must be
//     url(#id) and href must be #id;
//   - no comments, CDATA, doctype, entities or processing instructions.
//
// The frontend shows art only through <img>, which never runs scripts; this
// check is the defence in depth for every other place a data: URI ends up
// (wallets, explorers, indexers; RA M-7, design §5.4).
func AssertSVG(svg string, maxBytes int) error {
	if len(svg) == 0 {
		return errors.New("svg: empty")
	}
	if len(svg) > maxBytes {
		return errors.New("svg: larger than " + strconv.Itoa(maxBytes) + " bytes")
	}
	if !utf8.ValidString(svg) {
		return errors.New("svg: invalid UTF-8")
	}
	if !strings.HasPrefix(svg, "<svg") || !strings.HasSuffix(svg, "</svg>") {
		return errors.New("svg: must start with <svg and end with </svg>")
	}
	p := &svgParser{s: svg}
	return p.run()
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

// svgAttributes are geometry, paint and filter attributes. Absent on
// purpose: style, on*, src, every animation attribute (attributeName, to,
// from, by, begin), and every prefixed name except xlink:href.
var svgAttributes = map[string]bool{
	"id": true, "class": true, "version": true, "viewBox": true, "preserveAspectRatio": true,
	"x": true, "y": true, "x1": true, "y1": true, "x2": true, "y2": true,
	"cx": true, "cy": true, "r": true, "rx": true, "ry": true, "fx": true, "fy": true, "fr": true,
	"width": true, "height": true, "d": true, "points": true, "pathLength": true,
	"transform": true, "href": true, "xlink:href": true,
	"fill": true, "fill-opacity": true, "fill-rule": true,
	"stroke": true, "stroke-width": true, "stroke-opacity": true, "stroke-linecap": true,
	"stroke-linejoin": true, "stroke-dasharray": true, "stroke-dashoffset": true, "stroke-miterlimit": true,
	"opacity": true, "color": true, "visibility": true, "display": true,
	"clip-path": true, "clip-rule": true, "mask": true, "filter": true,
	"shape-rendering": true, "vector-effect": true, "paint-order": true, "mix-blend-mode": true,
	"font-family": true, "font-size": true, "font-weight": true, "font-style": true,
	"text-anchor": true, "dominant-baseline": true, "letter-spacing": true,
	"textLength": true, "lengthAdjust": true, "dx": true, "dy": true, "rotate": true,
	"gradientUnits": true, "gradientTransform": true, "spreadMethod": true,
	"offset": true, "stop-color": true, "stop-opacity": true,
	"patternUnits": true, "patternContentUnits": true, "patternTransform": true,
	"clipPathUnits": true, "maskUnits": true, "maskContentUnits": true,
	"filterUnits": true, "primitiveUnits": true, "result": true, "in": true, "in2": true,
	"stdDeviation": true, "mode": true, "type": true, "values": true, "operator": true,
	"k1": true, "k2": true, "k3": true, "k4": true, "radius": true,
	"flood-color": true, "flood-opacity": true, "baseFrequency": true, "numOctaves": true,
	"seed": true, "stitchTiles": true, "scale": true, "xChannelSelector": true, "yChannelSelector": true,
	"tableValues": true, "slope": true, "intercept": true, "amplitude": true, "exponent": true,
	"xmlns": true, "xmlns:xlink": true,
}

type svgParser struct {
	s     string
	i     int
	stack []string
}

func svgErr(msg string) error { return errors.New("svg: " + msg) }

func (p *svgParser) run() error {
	rootDone := false
	for p.i < len(p.s) {
		if rootDone {
			return svgErr("content after the root element")
		}
		if p.s[p.i] != '<' {
			if err := p.text(); err != nil {
				return err
			}
			continue
		}
		if p.i+1 >= len(p.s) {
			return svgErr("unterminated tag")
		}
		c := p.s[p.i+1]
		switch {
		case c == '!':
			return svgErr("comments, CDATA, doctype and entity declarations are not allowed")
		case c == '?':
			return svgErr("processing instructions are not allowed")
		case c == '/':
			if err := p.closeTag(); err != nil {
				return err
			}
			if len(p.stack) == 0 {
				rootDone = true
			}
		default:
			first := len(p.stack) == 0
			name, selfClosed, err := p.openTag()
			if err != nil {
				return err
			}
			if first && name != "svg" {
				return svgErr("the root element must be <svg>")
			}
			if selfClosed && len(p.stack) == 0 {
				rootDone = true
			}
		}
	}
	if len(p.stack) != 0 {
		return svgErr("unclosed element <" + p.stack[len(p.stack)-1] + ">")
	}
	if !rootDone {
		return svgErr("no root element")
	}
	return nil
}

// text is character data: printable characters, whitespace and the five
// XML entities only.
func (p *svgParser) text() error {
	if len(p.stack) == 0 {
		return svgErr("text outside the root element")
	}
	start := p.i
	for p.i < len(p.s) && p.s[p.i] != '<' {
		p.i++
	}
	return checkChars(p.s[start:p.i], true)
}

func (p *svgParser) openTag() (string, bool, error) {
	p.i++ // '<'
	name := p.name()
	if name == "" {
		return "", false, svgErr("malformed tag")
	}
	if strings.Contains(name, ":") || !svgElements[name] {
		return "", false, svgErr("element <" + name + "> is not allowed")
	}
	seen := map[string]bool{}
	for {
		sp := p.spaces()
		if p.i >= len(p.s) {
			return "", false, svgErr("unterminated tag <" + name + ">")
		}
		switch p.s[p.i] {
		case '>':
			p.i++
			p.stack = append(p.stack, name)
			return name, false, nil
		case '/':
			if p.i+1 >= len(p.s) || p.s[p.i+1] != '>' {
				return "", false, svgErr("malformed tag <" + name + ">")
			}
			p.i += 2
			return name, true, nil
		}
		if !sp {
			return "", false, svgErr("attributes must be separated by whitespace in <" + name + ">")
		}
		attr := p.name()
		if attr == "" {
			return "", false, svgErr("malformed attribute in <" + name + ">")
		}
		if seen[attr] {
			return "", false, svgErr("duplicate attribute " + attr)
		}
		seen[attr] = true
		p.spaces()
		if p.i >= len(p.s) || p.s[p.i] != '=' {
			return "", false, svgErr("attribute " + attr + " needs a value")
		}
		p.i++
		p.spaces()
		if p.i >= len(p.s) || (p.s[p.i] != '"' && p.s[p.i] != '\'') {
			return "", false, svgErr("attribute " + attr + " must be quoted")
		}
		q := p.s[p.i]
		p.i++
		start := p.i
		for p.i < len(p.s) && p.s[p.i] != q {
			p.i++
		}
		if p.i >= len(p.s) {
			return "", false, svgErr("unterminated value of " + attr)
		}
		val := p.s[start:p.i]
		p.i++
		if err := checkAttr(name, attr, val); err != nil {
			return "", false, err
		}
	}
}

func (p *svgParser) closeTag() error {
	p.i += 2 // "</"
	name := p.name()
	p.spaces()
	if p.i >= len(p.s) || p.s[p.i] != '>' {
		return svgErr("malformed closing tag")
	}
	p.i++
	if len(p.stack) == 0 || p.stack[len(p.stack)-1] != name {
		return svgErr("mismatched closing tag </" + name + ">")
	}
	p.stack = p.stack[:len(p.stack)-1]
	return nil
}

// name reads an XML name made of ASCII letters, digits, '-', '_', '.', ':'.
func (p *svgParser) name() string {
	start := p.i
	for p.i < len(p.s) {
		c := p.s[p.i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == ':' ||
			(p.i > start && ((c >= '0' && c <= '9') || c == '-' || c == '.')) {
			p.i++
			continue
		}
		break
	}
	return p.s[start:p.i]
}

func (p *svgParser) spaces() bool {
	start := p.i
	for p.i < len(p.s) && isSpace(p.s[p.i]) {
		p.i++
	}
	return p.i > start
}

func checkAttr(elem, attr, val string) error {
	if !svgAttributes[attr] {
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
