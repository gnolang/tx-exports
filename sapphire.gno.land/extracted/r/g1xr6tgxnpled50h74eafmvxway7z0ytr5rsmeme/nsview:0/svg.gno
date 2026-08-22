package nsview

import (
	"encoding/base64"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata"
)

// The NFT artwork and every piece of display formatting live here, in a
// realm that can be redeployed, rather than in the vault that cannot.
// nsdata.TokenURI points at this realm through a settable prefix.

// TokenURI returns the full data: URI for a token, generated on every
// read so the image always reflects current state (never baked at mint).
func TokenURI(tid string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(BuildSVG(tid)))
}

func BuildSVG(tid string) string {
	var expires time.Time
	var streak int64
	var frozen bool

	if strings.HasPrefix(tid, "*") {
		label := tid[1:]
		if !nsdata.DomainExists(label) {
			return placeholderSVG("unknown")
		}
		_, _, expires, streak, frozen = nsdata.GetDomainInfo(label)
	} else {
		label, domainLabel := splitTokenID(tid)
		if !nsdata.NameExists(label, domainLabel) {
			return placeholderSVG("unknown")
		}
		_, _, expires, streak, frozen, _ = nsdata.GetNameInfo(label, domainLabel)
	}

	status, statusColor, daysLine := statusFields(expires)
	if frozen {
		status, statusColor = "FROZEN", "#8888aa"
	}

	return ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  <rect width="400" height="400" fill="#10101a"/>
  <rect x="12" y="12" width="376" height="376" rx="16" fill="none" stroke="%s" stroke-width="3"/>
  <text x="200" y="170" text-anchor="middle" font-family="monospace" font-size="30" font-weight="bold" fill="#ffffff">%s</text>

  <text x="200" y="215" text-anchor="middle" font-family="monospace" font-size="16" fill="#cccccc">
    <tspan>%s</tspan>
    <animate attributeName="opacity" values="1;1;0;0" keyTimes="0;0.499;0.5;1" dur="10s" repeatCount="indefinite"/>
  </text>
  <text x="200" y="215" text-anchor="middle" font-family="monospace" font-size="16" fill="#cccccc" opacity="0">
    <tspan>%s</tspan>
    <animate attributeName="opacity" values="0;0;1;1" keyTimes="0;0.499;0.5;1" dur="10s" repeatCount="indefinite"/>
  </text>

  <text x="200" y="245" text-anchor="middle" font-family="monospace" font-size="13" fill="#999999">%s</text>
  <text x="200" y="270" text-anchor="middle" font-family="monospace" font-size="13" fill="#999999">%d yr streak</text>
  <text x="200" y="360" text-anchor="middle" font-family="monospace" font-size="15" font-weight="bold" fill="%s">%s</text>
</svg>`,
		statusColor, escapeXML(tid),
		expires.Format("2006-01-02"), expires.Format("Jan 2, 2006"),
		daysLine, streak, statusColor, status)
}

func placeholderSVG(msg string) string {
	return ufmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">`+
		`<rect width="400" height="400" fill="#10101a"/>`+
		`<text x="200" y="200" text-anchor="middle" font-family="monospace" font-size="18" fill="#666680">%s</text></svg>`,
		escapeXML(msg))
}

// statusFields formats a lifecycle state for display. Reads the grace
// period from nsdata rather than hardcoding it, so retuning the lifecycle
// is a config change and this stays correct.
func statusFields(expires time.Time) (status, color, daysLine string) {
	now := time.Now()
	grace := nsdata.GetGracePeriod()
	switch {
	case now.Before(expires):
		return "VALID", "#4ade80", ufmt.Sprintf("%d days left", int64(expires.Sub(now)/(24*time.Hour)))
	case now.Before(expires.Add(grace)):
		left := int64(expires.Add(grace).Sub(now) / (24 * time.Hour))
		return "GRACE PERIOD", "#facc15", ufmt.Sprintf("%d days to reclaim", left)
	default:
		return "EXPIRED", "#f87171", "available to register"
	}
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}
