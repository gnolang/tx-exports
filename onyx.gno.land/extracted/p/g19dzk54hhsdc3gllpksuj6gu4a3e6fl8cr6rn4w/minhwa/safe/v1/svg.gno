package safe

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// forbiddenSVG lists constructs that can run code, load something from the
// network or redefine the document. Engines draw with shapes and paths;
// none of these is needed for that (RA M-7).
var forbiddenSVG = []string{
	"<script", "javascript:", "vbscript:", "<foreignobject", "<iframe",
	"<object", "<embed", "<image", "<!entity", "<!doctype", "<?xml-stylesheet",
	"@import", "&#", // numeric character references would hide a scheme from this scan
}

// AssertSVG checks an engine's raw SVG output: size, envelope, the forbidden
// constructs above, inline event handlers, and any href or url() that does
// not point inside the document. The frontend shows art only through <img>,
// which never runs scripts; this check is the defence in depth for every
// other place a data: URI ends up (RA M-7, design §5.4).
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
	low := strings.ToLower(svg)
	for _, bad := range forbiddenSVG {
		if strings.Contains(low, bad) {
			return errors.New("svg: forbidden construct " + strconv.Quote(bad))
		}
	}
	if hasEventHandler(low) {
		return errors.New("svg: inline event handlers are not allowed")
	}
	if hasExternalRef(low, "href") || hasExternalRef(low, "url(") {
		return errors.New("svg: references must stay inside the document (#id)")
	}
	return nil
}

// hasEventHandler finds an attribute named on<letters> (onload=, onclick =).
func hasEventHandler(low string) bool {
	for i := 0; i+2 < len(low); i++ {
		if low[i] != 'o' || low[i+1] != 'n' {
			continue
		}
		if i > 0 && !isAttrBoundary(low[i-1]) {
			continue
		}
		j := i + 2
		for j < len(low) && low[j] >= 'a' && low[j] <= 'z' {
			j++
		}
		if j == i+2 {
			continue
		}
		for j < len(low) && isSpace(low[j]) {
			j++
		}
		if j < len(low) && low[j] == '=' {
			return true
		}
	}
	return false
}

// hasExternalRef reports an href attribute or url( whose target does not
// start with '#'. key is "href" (also matches xlink:href) or "url(".
func hasExternalRef(low, key string) bool {
	rest := low
	for {
		i := strings.Index(rest, key)
		if i < 0 {
			return false
		}
		j := i + len(key)
		if key == "href" {
			for j < len(rest) && isSpace(rest[j]) {
				j++
			}
			if j >= len(rest) || rest[j] != '=' {
				rest = rest[i+len(key):]
				continue
			}
			j++
		}
		for j < len(rest) && (isSpace(rest[j]) || rest[j] == '"' || rest[j] == '\'') {
			j++
		}
		if j >= len(rest) || rest[j] != '#' {
			return true
		}
		rest = rest[j:]
	}
}

func isAttrBoundary(c byte) bool {
	return isSpace(c) || c == '"' || c == '\'' || c == '/'
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}
