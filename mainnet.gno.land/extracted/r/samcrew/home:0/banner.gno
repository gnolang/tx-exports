package home

import "encoding/base64"

// This file is shared, unchanged, by every Samouraï home realm, so the pages
// keep one visual identity. What differs lives in content.gno.

// toriiMask is the Samouraï Coop mark, redrawn as vectors: a torii gate cut
// out of a full circle, in a 480x480 box. Everything painted through the mask
// takes the shape of the mark.
const toriiMask = `<mask id="torii"><circle cx="238" cy="240" r="240" fill="#fff"/><g fill="#000">` +
	`<path d="M-10 90 Q238 164 490 90 L490 140 Q238 190 -10 140 Z"/>` +
	`<path d="M102 140 L165 140 L162 206 L96 206 Z"/>` +
	`<path d="M302 140 L364 140 L370 206 L304 206 Z"/>` +
	`<rect x="-10" y="205" width="500" height="41"/>` +
	`<path d="M89 245 L159 245 L145 490 L55 490 Z"/>` +
	`<rect x="-10" y="274" width="100" height="32"/>` +
	`<path d="M307 245 L377 245 L411 490 L321 490 Z"/>` +
	`<path d="M382 296 L490 398 L490 455 L390 358 Z"/>` +
	`</g></mask>`

type heroText struct {
	kicker   string // small red caps line above the title
	title    string
	subtitle string
	tagline  string // red monospace line
	footline string // grey monospace line
	alt      string
}

// heroSVG draws the page banner: the mark set in a red sun on the right, the
// text stack on the left.
func heroSVG(h heroText) string {
	return `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="300" viewBox="0 0 960 300">` +
		`<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0e0e0e"/><stop offset="1" stop-color="#2a0c10"/></linearGradient>` +
		toriiMask + `</defs>` +
		`<rect width="960" height="300" rx="18" fill="url(#bg)"/>` +
		`<g stroke="#ffffff" stroke-opacity=".05"><path d="M0 60H960M0 120H960M0 180H960M0 240H960"/></g>` +
		`<circle cx="790" cy="150" r="128" fill="#e63946"/>` +
		`<g transform="translate(686 46) scale(.4333)"><rect width="480" height="480" fill="#f4efe6" mask="url(#torii)"/></g>` +
		`<text x="56" y="78" font-family="ui-monospace,Menlo,monospace" font-size="13" letter-spacing="3" fill="#e63946">` + xmlText(h.kicker) + `</text>` +
		`<text x="52" y="160" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-weight="800" font-size="76" fill="#ffffff">` + xmlText(h.title) + `</text>` +
		`<text x="56" y="200" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-size="22" fill="#e8e2d8">` + xmlText(h.subtitle) + `</text>` +
		`<text x="56" y="236" font-family="ui-monospace,Menlo,monospace" font-size="16" fill="#e63946">` + xmlText(h.tagline) + `</text>` +
		`<text x="56" y="266" font-family="ui-monospace,Menlo,monospace" font-size="12" fill="#8a8a8a">` + xmlText(h.footline) + `</text>` +
		`</svg>`
}

func heroImage() string {
	return "![" + mdText(hero.alt) + "](data:image/svg+xml;base64," +
		base64.StdEncoding.EncodeToString([]byte(heroSVG(hero))) + ")"
}
