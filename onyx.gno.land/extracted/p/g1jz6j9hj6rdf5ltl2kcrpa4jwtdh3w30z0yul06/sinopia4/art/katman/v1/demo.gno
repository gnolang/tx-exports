// Code generated from the Katman kit source (docs/engines/katman.md, "Demo kit"). The TS twin
// (frontend/src/engines/katman.ts) holds the same literals; katman_test.gno pins both.

package katman

// demoLayers is the demo kit (params store 0): layer name, then part name, weight and
// inner SVG ("" = the layer is empty for this part). Layer order is z-order, bottom first.
var demoLayers = []layer{
	{"Ground", []part{
		{"Sun Disc", 30, `<circle cx="200" cy="200" r="152" fill="currentColor"/><circle cx="200" cy="200" r="136" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="3" stroke-dasharray="2 9" stroke-linecap="round"/>`},
		{"Bands", 25, `<path d="M0 58h400v40H0zM0 168h400v40H0zM0 278h400v40H0z" fill="currentColor"/><path d="M0 116h400M0 226h400M0 336h400" stroke="currentColor" stroke-width="3" stroke-opacity=".5"/>`},
		{"Arch", 25, `<path d="M64 400V214a136 136 0 0 1 272 0v186z" fill="currentColor"/><path d="M88 400V218a112 112 0 0 1 224 0v182" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="3"/>`},
		{"Polka", 12, `<g fill="currentColor"><circle cx="50" cy="50" r="10"/><circle cx="150" cy="50" r="10"/><circle cx="250" cy="50" r="10"/><circle cx="350" cy="50" r="10"/><circle cx="50" cy="150" r="10"/><circle cx="150" cy="150" r="10"/><circle cx="250" cy="150" r="10"/><circle cx="350" cy="150" r="10"/><circle cx="50" cy="250" r="10"/><circle cx="150" cy="250" r="10"/><circle cx="250" cy="250" r="10"/><circle cx="350" cy="250" r="10"/><circle cx="50" cy="350" r="10"/><circle cx="150" cy="350" r="10"/><circle cx="250" cy="350" r="10"/><circle cx="350" cy="350" r="10"/><circle cx="100" cy="100" r="6"/><circle cx="200" cy="100" r="6"/><circle cx="300" cy="100" r="6"/><circle cx="100" cy="200" r="6"/><circle cx="200" cy="200" r="6"/><circle cx="300" cy="200" r="6"/><circle cx="100" cy="300" r="6"/><circle cx="200" cy="300" r="6"/><circle cx="300" cy="300" r="6"/></g>`},
		{"Plain", 8, ``},
	}},
	{"Body", []part{
		{"Jar", 35, `<ellipse cx="200" cy="374" rx="112" ry="11" fill="#2a1d17" fill-opacity=".16"/><path d="M150 130h100v26q72 36 64 124q-8 84-114 84T86 280q-8-88 64-124z" fill="currentColor" stroke="#2a1d17" stroke-width="6" stroke-linejoin="round"/><path d="M150 156h100" stroke="#2a1d17" stroke-width="5"/><path d="M112 262q4-56 50-86" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10" stroke-linecap="round"/>`},
		{"Amphora", 25, `<ellipse cx="200" cy="392" rx="64" ry="11" fill="#2a1d17" fill-opacity=".16"/><path d="M170 96h60v42q64 40 54 140q-8 72-84 112q-76-40-84-112q-10-100 54-140z" fill="currentColor" stroke="#2a1d17" stroke-width="6" stroke-linejoin="round"/><path d="M170 138h60" stroke="#2a1d17" stroke-width="5"/><path d="M138 268q0-62 40-102" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10" stroke-linecap="round"/>`},
		{"Pot", 25, `<ellipse cx="200" cy="366" rx="116" ry="11" fill="#2a1d17" fill-opacity=".16"/><path d="M130 160h140q66 54 46 140q-18 58-116 58T84 300q-20-86 46-140z" fill="currentColor" stroke="#2a1d17" stroke-width="6" stroke-linejoin="round"/><ellipse cx="200" cy="160" rx="74" ry="9" fill="currentColor" stroke="#2a1d17" stroke-width="5"/><path d="M106 286q-2-58 40-104" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10" stroke-linecap="round"/>`},
		{"Pitcher", 15, `<ellipse cx="200" cy="374" rx="104" ry="11" fill="#2a1d17" fill-opacity=".16"/><path d="M242 120l30-16-10 34" fill="currentColor" stroke="#2a1d17" stroke-width="6" stroke-linejoin="round"/><path d="M158 118h84l-8 34q78 38 72 128q-6 84-106 86q-100-2-106-86q-6-90 72-128z" fill="currentColor" stroke="#2a1d17" stroke-width="6" stroke-linejoin="round"/><path d="M114 270q0-60 48-100" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10" stroke-linecap="round"/>`},
	}},
	{"Glaze", []part{
		{"Zigzag", 30, `<path d="M136 302l22-16 22 16 22-16 22 16 22-16 22 16" fill="none" stroke="currentColor" stroke-width="8" stroke-linejoin="round" stroke-linecap="round"/>`},
		{"Dots", 28, `<path d="M148 300h.1M174 316h.1M200 300h.1M226 316h.1M252 300h.1" stroke="currentColor" stroke-width="16" stroke-linecap="round"/>`},
		{"Wave", 22, `<path d="M136 306q16-18 32 0t32 0 32 0 32 0" fill="none" stroke="currentColor" stroke-width="9" stroke-linecap="round"/>`},
		{"Twin Bands", 12, `<path d="M140 292h120M140 320h120" stroke="currentColor" stroke-width="7" stroke-linecap="round"/>`},
		{"Bare", 8, ``},
	}},
	{"Face", []part{
		{"Happy", 30, `<g fill="#e07a5f" fill-opacity=".45"><ellipse cx="154" cy="244" rx="12" ry="7"/><ellipse cx="246" cy="244" rx="12" ry="7"/></g><g fill="#2a1d17"><circle cx="172" cy="220" r="8"/><circle cx="228" cy="220" r="8"/></g><path d="M178 248q22 20 44 0" fill="none" stroke="#2a1d17" stroke-width="6" stroke-linecap="round"/>`},
		{"Sleepy", 25, `<path d="M160 222q12 8 24 0M216 222q12 8 24 0" fill="none" stroke="#2a1d17" stroke-width="6" stroke-linecap="round"/><circle cx="200" cy="252" r="7" fill="#2a1d17"/>`},
		{"Surprised", 18, `<g fill="#fff" stroke="#2a1d17" stroke-width="5"><circle cx="172" cy="218" r="14"/><circle cx="228" cy="218" r="14"/></g><g fill="#2a1d17"><circle cx="175" cy="220" r="5"/><circle cx="231" cy="220" r="5"/><ellipse cx="200" cy="256" rx="9" ry="12"/></g>`},
		{"Wink", 15, `<g fill="#e07a5f" fill-opacity=".45"><ellipse cx="154" cy="244" rx="12" ry="7"/><ellipse cx="246" cy="244" rx="12" ry="7"/></g><path d="M160 222q12-10 24 0M176 246q24 22 48 0" fill="none" stroke="#2a1d17" stroke-width="6" stroke-linecap="round"/><circle cx="228" cy="220" r="8" fill="#2a1d17"/>`},
		{"Grumpy", 12, `<path d="M158 204l26 8M242 204l-26 8M180 258h40" fill="none" stroke="#2a1d17" stroke-width="6" stroke-linecap="round"/><g fill="#2a1d17"><circle cx="172" cy="224" r="7"/><circle cx="228" cy="224" r="7"/></g>`},
	}},
	{"Handle", []part{
		{"Single", 35, `<path d="M286 176q78 8 44 100" fill="none" stroke="#2a1d17" stroke-width="18" stroke-linecap="round"/><path d="M286 176q78 8 44 100" fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round"/>`},
		{"Pair", 30, `<path d="M114 176q-78 8-44 100M286 176q78 8 44 100" fill="none" stroke="#2a1d17" stroke-width="18" stroke-linecap="round"/><path d="M114 176q-78 8-44 100M286 176q78 8 44 100" fill="none" stroke="currentColor" stroke-width="8" stroke-linecap="round"/>`},
		{"Ears", 10, `<path d="M152 150q-42-8-36 30M248 150q42-8 36 30" fill="none" stroke="#2a1d17" stroke-width="14" stroke-linecap="round"/><path d="M152 150q-42-8-36 30M248 150q42-8 36 30" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round"/>`},
		{"None", 25, ``},
	}},
	{"Crown", []part{
		{"Flower", 25, `<path d="M200 130V70" stroke="#4f7a3a" stroke-width="6"/><g fill="currentColor" stroke="#2a1d17" stroke-width="4"><circle cx="200" cy="52" r="14"/><circle cx="182" cy="68" r="14"/><circle cx="218" cy="68" r="14"/></g><circle cx="200" cy="64" r="7" fill="#f2cc8f"/>`},
		{"Lid", 25, `<ellipse cx="200" cy="124" rx="62" ry="14" fill="currentColor" stroke="#2a1d17" stroke-width="5"/><circle cx="200" cy="104" r="11" fill="currentColor" stroke="#2a1d17" stroke-width="5"/>`},
		{"Steam", 20, `<path d="M180 110q-16-20 0-40t0-40M220 110q-16-20 0-40t0-40" fill="none" stroke="currentColor" stroke-width="7" stroke-linecap="round"/>`},
		{"Sprout", 18, `<path d="M200 128V84" stroke="#4f7a3a" stroke-width="6" stroke-linecap="round"/><path d="M200 100q-32-2-38-30q32-2 38 30zM200 92q30-4 36-30q-32 0-36 30z" fill="currentColor" stroke="#2a1d17" stroke-width="4" stroke-linejoin="round"/>`},
		{"Bird", 12, `<path d="M176 120q4-34 40-30q18-14 26 4l-14 6q4 20-26 22z" fill="currentColor" stroke="#2a1d17" stroke-width="5" stroke-linejoin="round"/><path d="M194 104q10 8 22 0" fill="none" stroke="#2a1d17" stroke-width="4" stroke-linecap="round"/><circle cx="226" cy="98" r="3" fill="#2a1d17"/>`},
	}},
}

// palettes: name, paper ("" = no paper rect) and eight inks. The last one, Kit Colours,
// leaves the kit's own colours alone (no paper, no color attributes).
var palettes = []palette{
	{"Terracotta", "#f6efe3", []string{"#e07a5f", "#3d405b", "#81b29a", "#f2cc8f", "#6d597a", "#b56576", "#5e8c9a", "#c9a227"}},
	{"Riso", "#f4ede0", []string{"#ff48b0", "#0078bf", "#ffe14a", "#00a95c", "#ff6c2f", "#765ba7", "#5ec8e5", "#f15060"}},
	{"Iznik", "#f7f3ea", []string{"#1f5fa8", "#2a9d8f", "#c8102e", "#e9c46a", "#264653", "#6fb7d6", "#b5432c", "#3a7d44"}},
	{"Sea Glass", "#eef3ef", []string{"#7fb7be", "#bc4b51", "#5b8e7d", "#f4e285", "#8cb369", "#3c6e71", "#e7b7a3", "#d3a588"}},
	{"Dusk", "#262338", []string{"#f2a65a", "#e85d75", "#8d5a97", "#5bc0be", "#f9dc5c", "#c3bef7", "#ee6c4d", "#6c91c2"}},
	{"Sinopia", "#efe4cc", []string{"#b5432c", "#2e4a3a", "#d9a441", "#7a2e1f", "#4a6670", "#c97b5a", "#8c6d46", "#e3c08d"}},
	{"Mono", "#f2f0eb", []string{"#1c1c1c", "#4a4a4a", "#7a7a7a", "#a8a8a8", "#d0d0d0", "#2f2f2f", "#5e5e5e", "#8f8f8f"}},
	{"Kit Colours", "", []string{}},
}
