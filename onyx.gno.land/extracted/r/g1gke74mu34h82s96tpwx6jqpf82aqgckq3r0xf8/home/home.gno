package home

// Render returns the profile page markdown served by gnoweb.
// gnoweb calls Render("") for /r/nym-transtangible420/home,
// which backs the profile at /u/nym-transtangible420.
func Render(path string) string {
	if path != "" {
		return "# nym-transtangible420\n\nNo such subpage: `" + path + "`\n"
	}
	return `# nym-transtangible420

> Building on Gno.land — deterministic, human-readable smart contracts.

## About

- **Name:** nym-transtangible420
- **Realm:** gno.land/r/nym-transtangible420/home
- **Status:** local dev — deploy to Onyx testnet pending (TODO #4)

## Links

- [gno.land profile](https://gno.land/u/nym-transtangible420)
- More links coming soon (placeholder).

---

*Rendered by a Gno realm. Deployed from the OpenClaw + Gnoland workspace.*
`
}
