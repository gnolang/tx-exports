package nsdata

// The real human-facing view moved OUT of this realm into `nsview`
// (2026-08-21), after an adversarial review found three separate
// defects in the old Render() — unescaped profile-field injection into
// the markdown, an O(domains × names) home page any user could inflate
// into a permanent DoS, and links that 404'd — none of which could ever
// be fixed, because this realm is deployed once and never replaced.
//
// The lesson generalised: "it's only display code, it has no
// authorization surface" was the wrong test for what belongs in an
// immutable realm. The right test is whether a bug in it would be
// permanent. Display code changes far more often than storage schemas
// do, so it belongs in something swappable.
//
// What remains here is deliberately a fixed string: no user-authored
// data, no iteration over state, nothing that can be wrong later.
func Render(path string) string {
	return "# Meme Name Service — data realm\n\n" +
		"This realm stores records only: name and domain ownership, " +
		"configuration, and the NFT state.\n\n" +
		"The human-facing view lives in the `nsview` realm; writes go " +
		"through `nslogic`.\n"
}
