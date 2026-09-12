package kourt2
import (
	"chain"
	"strconv"
	"strings"
)
const maxSiteDomainLen = 100
var siteDomain string
func siteDomainFault(d string) string {
	if len(d) < 4 || len(d) > maxSiteDomainLen {
		return "a site domain is 4..100 characters"
	}
	if !strings.Contains(d, ".") {
		return "a site domain needs a dot — it is a hostname, not a word"
	}
	if d[0] == '.' || d[0] == '-' || d[len(d)-1] == '.' || d[len(d)-1] == '-' {
		return "a site domain may not begin or end with a dot or a hyphen"
	}
	for i := 0; i < len(d); i++ {
		c := d[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'
		if !ok {
			return "a site domain is lowercase letters, digits, dots and " +
				"hyphens only — no scheme, no path, no port"
		}
	}
	if strings.Contains(d, "..") {
		return "a site domain may not contain an empty label"
	}
	return ""
}
func mustSiteDomain(d string) {
	if fault := siteDomainFault(d); fault != "" {
		panic("kourtv2: " + fault)
	}
}
func SetSiteDomain(cur realm, domain string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the site domain")
	}
	mustSiteDomain(domain)
	siteDomain = domain
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-site-domain:"+domain,
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func ClearSiteDomain(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin clears the site domain")
	}
	if siteDomain == "" {
		panic("kourtv2: no site domain is set")
	}
	siteDomain = ""
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "clear-site-domain",
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func SiteDomain() string { return siteDomain }
func sitePath(path string) string {
	parts := strings.SplitN(path, "/", 4)
	if path == "" || parts[0] == "" {
		return "#/"
	}
	if len(parts) == 1 {
		if parts[0] == helpPath {
			return "#/"
		}
		if parts[0] == adminParamsPath {
			return "#/params"
		}
		return "#/c/" + parts[0]
	}
	switch parts[1] {
	case "me":
		return "#/me"
	case "mod":
		return "#/c/" + parts[0]
	}
	if _, err := strconv.ParseUint(parts[1], 10, 64); err != nil {
		return "#/c/" + parts[0]
	}
	return "#/c/" + parts[0] + "/" + parts[1]
}
func withSiteBanner(body, path string) string {
	bar := siteBanner(path)
	if bar == "" {
		return body
	}
	if !strings.HasPrefix(body, "# ") {
		return bar + body
	}
	i := strings.Index(body, "\n")
	if i < 0 {
		return body + "\n\n" + bar
	}
	return body[:i+1] + "\n" + bar + strings.TrimLeft(body[i+1:], "\n")
}
func siteBanner(path string) string {
	if siteDomain == "" || siteDomainFault(siteDomain) != "" {
		return ""
	}
	return "[Read this on " + siteDomain + " →](https://" + siteDomain + "/" +
		sitePath(path) + ")\n\n"
}
