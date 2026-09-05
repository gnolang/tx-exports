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
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsskin/v1"
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
	/* nsskin.TokenURI hands out "/r/.../nsview:skin/<id>#<n>" and this
	   case did not exist, so every skin token resolved to the literal
	   string "404: unknown name" — splitTokenID found no "*", the whole
	   path became a label, and renderName 404'd. All 226 lines of
	   skincard.gno, including the matted frame and the SKIN label its
	   own header calls the mitigation for "the single most likely way
	   this product hurts somebody", never ran for anybody. */
	case strings.HasPrefix(path, "skin/"):
		return "```\n" + renderSkin(strings.TrimPrefix(path, "skin/")) + "\n```\n"
	default:
		// A domain page carries its cursor as "?after=<key>". Split it
		// off before the token id is parsed, or the cursor lands in the
		// label and every paged link 404s.
		route, after := path, ""
		if q := strings.Index(path, "?after="); q >= 0 {
			route, after = path[:q], path[q+len("?after="):]
		}
		label, domainLabel := splitTokenID(route)
		if label == "" {
			return renderDomain(domainLabel, after)
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
		/* NO COUNT HERE. This called nsdata.CountNames per domain, and
		   CountNames iterates that domain's whole key span — so the home
		   page was O(every name in the registry) on every single view,
		   and anyone could inflate it by registering names. That is the
		   exact denial of service this package's own doc comment says
		   forced the renderer out of the vault; moving it here made it
		   repairable and nobody repaired it. The count lives on the
		   domain's own page, which walks one domain and pages. */
		out += ufmt.Sprintf("- [*%s](*%s) — owner `%s`\n",
			label, label, owner.String())
	}
	return out
}

func renderDomain(domainLabel, after string) string {
	if !nsdata.DomainExists(domainLabel) {
		return "404: unknown domain\n"
	}
	owner, registered, expires, streak, frozen := nsdata.GetDomainInfo(domainLabel)
	status, _ := statusFields(expires, frozen)
	daysLine := remaining(expires, time.Now().Unix())

	out := ufmt.Sprintf("# *%s\n\n", domainLabel)
	out += ufmt.Sprintf("- owner: `%s`\n", owner.String())
	out += ufmt.Sprintf("- status: **%s** (%s)\n", status, daysLine)
	if frozen {
		out += "- **frozen**\n"
	}
	out += ufmt.Sprintf("- registered: %s\n", time.Unix(registered, 0).UTC().Format("2006-01-02"))
	out += ufmt.Sprintf("- renewal streak: %d year(s)\n\n", streak)

	/* PAGED. This listed every name under the domain in one pass and
	   built a markdown line for each, so a domain with enough names made
	   its own page too expensive to render — permanently, for everyone,
	   until this realm was redeployed. nsdata.ExportNames already pages;
	   nsmarket already uses the same cursor idea for listings. */
	out += renderDomainNames(domainLabel, after)
	return out
}

// namePage is how many names one domain page shows. Small enough that
// the work is bounded whatever the registry does, large enough that an
// ordinary domain is one page.
const namePage = 100

func renderDomainNames(domainLabel, after string) string {
	keys, next := nsdata.ExportNames(domainLabel, after, namePage)
	labels := splitCSV(keys)
	if len(labels) == 0 {
		if after == "" {
			return "## names under this domain\n\n_none yet_\n"
		}
		return "## names under this domain\n\n_no more_\n"
	}

	out := "## names under this domain\n\n"
	// ExportNames returns full tree keys ("domain*label"); the page wants
	// the label, which is everything after the separator.
	cut := len(domainLabel) + 1
	for _, k := range labels {
		label := k
		if len(k) > cut {
			label = k[cut:]
		}
		out += ufmt.Sprintf("- [%s*%s](%s*%s)\n", label, domainLabel, label, domainLabel)
	}
	if next != "" {
		out += ufmt.Sprintf("\n[more](*%s?after=%s)\n", domainLabel, next)
	}
	return out
}

/*
renderSkin draws a skin DEFINITION's own card, matted and labelled, from
a token id of the form "<definition>#<serial>".

Deliberately not the name card: a skin for sale and a name for sale must
not look alike, which is what skincard.gno's frame is for.
*/
func renderSkin(tid string) string {
	id := tid
	if h := strings.Index(tid, "#"); h > 0 {
		id = tid[:h]
	}
	if !nsskin.SkinExists(id) {
		return "404: unknown skin"
	}
	name, art, lock, _, _, _ := nsskin.SkinInfo(id)
	return SkinCardSVG(name, art, lock, !inkForArt(art))
}

func renderName(label, domainLabel string) string {
	if !nsdata.NameExists(label, domainLabel) {
		return "404: unknown name\n"
	}
	owner, registered, expires, streak, frozen, isNFT := nsdata.GetNameInfo(label, domainLabel)
	status, _ := statusFields(expires, frozen)
	daysLine := remaining(expires, time.Now().Unix())

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
