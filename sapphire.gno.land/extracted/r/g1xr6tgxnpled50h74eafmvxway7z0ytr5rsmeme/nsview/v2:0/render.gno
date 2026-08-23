// Package nsview is the human-facing view — the third realm in the
// split, and the newest (2026-08-21).
//
// It exists because an adversarial review found three defects in the old
// Render(), which lived inside the permanent `nsdata` vault: unescaped
// profile text injected into the page markdown, an O(domains × names)
// home page any user could inflate into a permanent denial of service,
// and navigation links that 404'd. All three were display bugs, and none
// of them could ever have been fixed, because that realm is deployed
// exactly once. The NFT artwork moved here for the same reason.
//
// Display code is swappable now. This realm holds no state, reads
// everything from nsdata's exported API, and can be redeployed and
// re-pointed at any time with nothing to migrate.
package nsview

import (
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Profile keys inside a name's extension slot. Conventions owned by this
// realm and the logic realm, not by the vault — the vault stores strings
// and has no opinion about what they mean.
const (
	keyDisplayName = "displayName"
	keyBio         = "bio"
	keyWebsite     = "website"
)

func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "token/"):
		return "```\n" + BuildSVG(strings.TrimPrefix(path, "token/")) + "\n```\n"
	default:
		label, domainLabel := splitTokenID(path)
		if label == "" {
			return renderDomain(domainLabel)
		}
		return renderName(label, domainLabel)
	}
}

func renderHome() string {
	out := "# Meme Name Service\n\n"
	out += ufmt.Sprintf("%d domains registered.\n\n", nsdata.CountDomains())
	for _, label := range splitCSV(nsdata.ListDomains()) {
		owner, _, _, _, _ := nsdata.GetDomainInfo(label)
		// The link target must carry the "*" prefix — Render dispatches a
		// bare label to renderName, which 404s. That was the old home
		// page's bug: every link on it was dead.
		out += ufmt.Sprintf("- [*%s](*%s) — owner `%s` — %d name(s)\n",
			label, label, owner.String(), nsdata.CountNames(label))
	}
	return out
}

func renderDomain(domainLabel string) string {
	if !nsdata.DomainExists(domainLabel) {
		return "404: unknown domain\n"
	}
	owner, registered, expires, streak, frozen := nsdata.GetDomainInfo(domainLabel)
	status, _, daysLine := statusFields(expires)

	out := ufmt.Sprintf("# *%s\n\n", domainLabel)
	out += ufmt.Sprintf("- owner: `%s`\n", owner.String())
	out += ufmt.Sprintf("- status: **%s** (%s)\n", status, daysLine)
	if frozen {
		out += "- **frozen**\n"
	}
	out += ufmt.Sprintf("- registered: %s\n", time.Unix(registered, 0).UTC().Format("2006-01-02"))
	out += ufmt.Sprintf("- renewal streak: %d year(s)\n\n", streak)

	count := nsdata.CountNames(domainLabel)
	out += ufmt.Sprintf("## %d name(s) under this domain\n\n", count)
	for _, label := range splitCSV(nsdata.ListNames(domainLabel)) {
		out += ufmt.Sprintf("- [%s*%s](%s*%s)\n", label, domainLabel, label, domainLabel)
	}
	if count == 0 {
		out += "_none yet_\n"
	}
	return out
}

func renderName(label, domainLabel string) string {
	if !nsdata.NameExists(label, domainLabel) {
		return "404: unknown name\n"
	}
	owner, registered, expires, streak, frozen, isNFT := nsdata.GetNameInfo(label, domainLabel)
	status, _, daysLine := statusFields(expires)

	out := ufmt.Sprintf("# %s*%s\n\n", label, domainLabel)
	out += ufmt.Sprintf("- owner: `%s`\n", owner.String())
	out += ufmt.Sprintf("- status: **%s** (%s)\n", status, daysLine)
	if frozen {
		out += "- **frozen**\n"
	}
	if !isNFT {
		out += "- free tier (no token minted yet)\n"
	}
	out += ufmt.Sprintf("- registered: %s\n", time.Unix(registered, 0).UTC().Format("2006-01-02"))
	out += ufmt.Sprintf("- renewal streak: %d year(s)\n\n", streak)
	out += ufmt.Sprintf("- [*%s](*%s)\n\n", domainLabel, domainLabel)

	displayName := nsdata.GetNameExtra(label, domainLabel, keyDisplayName)
	bio := nsdata.GetNameExtra(label, domainLabel, keyBio)
	website := nsdata.GetNameExtra(label, domainLabel, keyWebsite)

	if displayName != "" || bio != "" || website != "" {
		out += "## Profile\n\n"
		// Every one of these is attacker-authored. Escaping them is the
		// whole reason this realm exists separately.
		if displayName != "" {
			out += ufmt.Sprintf("**%s**\n\n", escapeMarkdown(displayName))
		}
		if bio != "" {
			// A blockquote so even a crafted multi-line bio cannot break
			// out into block-level constructs.
			out += "> " + escapeMarkdown(bio) + "\n\n"
		}
		if website != "" {
			if isSafeURL(website) {
				out += ufmt.Sprintf("[%s](%s)\n\n", escapeMarkdown(website), website)
			} else {
				out += ufmt.Sprintf("website (unverified): `%s`\n\n", escapeMarkdown(website))
			}
		}
	}
	return out
}

// -- helpers --

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

// splitTokenID splits `label*domain`; a leading "*" yields an empty
// label, which is how a domain page is addressed.
func splitTokenID(tid string) (label, domain string) {
	for i := 0; i < len(tid); i++ {
		if tid[i] == '*' {
			return tid[:i], tid[i+1:]
		}
	}
	return tid, ""
}

// escapeMarkdown neutralises user-authored text so it renders as the
// literal characters typed rather than as markup. Backslash-escapes the
// CommonMark ASCII punctuation set and folds newlines, which stops
// headings, lists, tables, images, links, and raw HTML alike.
func escapeMarkdown(s string) string {
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte("\\`*_{}[]()#+-.!|<>&~\"'", c) >= 0 {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// isSafeURL only admits plain http/https. Everything else — javascript:,
// data:, anything unrecognised — is refused a live link. Checked on read
// rather than on write so tightening the rule later also applies to
// profiles that already exist.
func isSafeURL(u string) bool {
	if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		return false
	}
	if len(u) > 256 {
		return false
	}
	// This value is emitted RAW as the markdown link destination, so it is
	// the one attacker-authored string on the page that escapeMarkdown
	// does not neutralise. Allow-list instead of deny-list: every byte
	// must be printable, non-space ASCII. A deny-list missed newlines,
	// which let a crafted `website` terminate the link and inject
	// arbitrary markdown into the page below it.
	for i := 0; i < len(u); i++ {
		c := u[i]
		if c <= 0x20 || c >= 0x7f {
			return false
		}
		if strings.IndexByte("()<>\"'\\`", c) >= 0 {
			return false
		}
	}
	return true
}
