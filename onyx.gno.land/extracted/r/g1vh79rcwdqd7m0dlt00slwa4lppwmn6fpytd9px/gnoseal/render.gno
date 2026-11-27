package gnoseal

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// realmWebPath is this realm's gnoweb path; Render links are built from it
// in the form realmWebPath + ":cert/<id>".
const realmWebPath = "/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal"

// recentLimit caps how many certificates the home page lists.
const recentLimit = 20

// Render is the realm's web surface on gnoweb:
//
//	""             home: intro, totals, most recent certificates
//	"cert/<id>"    one certificate in full, including revoked state
//	"addr/<addr>"  every certificate issued to one address
//
// Stored titles, notes, and reasons are user-supplied text, so they are
// passed through sanitize.InlineText before being written into the
// Markdown output. Path segments are never echoed raw.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "cert/"):
		return renderCertPage(strings.TrimPrefix(path, "cert/"))
	case strings.HasPrefix(path, "addr/"):
		return renderAddrPage(strings.TrimPrefix(path, "addr/"))
	default:
		return "# GnoSeal\n\nUnknown page. [Back to GnoSeal home](" + realmWebPath + ")\n"
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# GnoSeal\n\n")
	b.WriteString("Verifiable onchain certificates on Gno.land. ")
	b.WriteString("An issuer creates a completion record for a recipient address; ")
	b.WriteString("anyone can verify it here, and only the issuer can revoke it, ")
	b.WriteString("with the reason written on chain.\n\n")
	b.WriteString("**Certificates issued:** " + strconv.FormatUint(Count(), 10) + "\n\n")
	b.WriteString("Look up a certificate at `" + realmWebPath + ":cert/<id>` ")
	b.WriteString("or all certificates for an address at `" + realmWebPath + ":addr/<address>`.\n\n")

	if len(certs) == 0 {
		b.WriteString("No certificates have been issued yet.\n")
		return b.String()
	}

	b.WriteString("## Recent certificates\n\n")
	start := 0
	if len(certs) > recentLimit {
		start = len(certs) - recentLimit
	}
	for i := len(certs) - 1; i >= start; i-- {
		b.WriteString(certListLine(certs[i]))
	}
	return b.String()
}

func renderCertPage(idStr string) string {
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		return "# GnoSeal\n\nCertificate not found. [Back to GnoSeal home](" + realmWebPath + ")\n"
	}
	cert, ok := findCert(id)
	if !ok {
		return "# GnoSeal\n\nCertificate not found. [Back to GnoSeal home](" + realmWebPath + ")\n"
	}

	var b strings.Builder
	b.WriteString("# Certificate #" + strconv.FormatUint(cert.ID, 10) + "\n\n")
	b.WriteString("**Title:** " + sanitize.InlineText(cert.Title) + "\n\n")
	b.WriteString("**Recipient:** " + cert.Recipient.String() + "\n\n")
	b.WriteString("**Issuer:** " + cert.Issuer.String() + "\n\n")
	b.WriteString("**Issued at block:** " + strconv.FormatInt(cert.Height, 10) + "\n\n")
	if cert.Revoked {
		b.WriteString("**Status:** Revoked\n\n")
		b.WriteString("**Revoke reason:** " + sanitize.InlineText(cert.RevokeReason) + "\n\n")
	} else {
		b.WriteString("**Status:** Valid\n\n")
	}
	if cert.Note != "" {
		b.WriteString("**Note:** " + sanitize.InlineText(cert.Note) + "\n\n")
	}
	b.WriteString("[All certificates for this recipient](" + realmWebPath + ":addr/" + cert.Recipient.String() + ")\n\n")
	b.WriteString("[Back to GnoSeal home](" + realmWebPath + ")\n")
	return b.String()
}

func renderAddrPage(addrStr string) string {
	addr := address(addrStr)
	if !addr.IsValid() {
		return "# GnoSeal\n\nThat is not a valid Gno address. [Back to GnoSeal home](" + realmWebPath + ")\n"
	}

	ids := byRecipient[addr]
	var b strings.Builder
	b.WriteString("# Certificates for " + addr.String() + "\n\n")
	if len(ids) == 0 {
		b.WriteString("No certificates have been issued to this address yet.\n\n")
	} else {
		for i := len(ids) - 1; i >= 0; i-- {
			cert, _ := findCert(ids[i])
			b.WriteString(certListLine(cert))
		}
		b.WriteString("\n")
	}
	b.WriteString("[Back to GnoSeal home](" + realmWebPath + ")\n")
	return b.String()
}

// certListLine renders one certificate as a Markdown list item linking to
// its detail page.
func certListLine(cert *Certificate) string {
	line := "- [#" + strconv.FormatUint(cert.ID, 10) + " · " +
		sanitize.InlineText(cert.Title) + "](" + realmWebPath + ":cert/" +
		strconv.FormatUint(cert.ID, 10) + ")" +
		" — issued to " + cert.Recipient.String() +
		" at block " + strconv.FormatInt(cert.Height, 10)
	if cert.Revoked {
		line += " · **Revoked**"
	}
	return line + "\n"
}
