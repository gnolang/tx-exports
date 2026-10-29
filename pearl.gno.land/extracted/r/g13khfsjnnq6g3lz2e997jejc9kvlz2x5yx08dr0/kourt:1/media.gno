package kourt
import (
	"chain"
	"strconv"
	"strings"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
func mediaDestination(m *mediaItem) string {
	if m.kind == mediaKindImage && m.sha256 != "" &&
		siteDomain != "" && siteDomainFault(siteDomain) == "" {
		return "https://" + siteDomain + "/m/" + m.sha256
	}
	for _, u := range m.mirrors {
		if mirrorFault(u) == "" {
			return u
		}
	}
	return ""
}
func verifyElsewhere() string {
	if siteDomain == "" || siteDomainFault(siteDomain) != "" {
		return ""
	}
	return " [" + siteDomain + "](https://" + siteDomain + ") checks it."
}
func writeClaimMedia(b *strings.Builder, c *Court, cs *claimState) {
	items := claimMediaVisible(c, cs)
	if len(items) == 0 {
		return
	}
	total := strconv.Itoa(len(items))
	b.WriteString("## Evidence filed with this claim\n\n")
	b.WriteString("_The court recorded a fingerprint of each image when the claim " +
		"was filed, so a swap can be detected — but not on this page._" + verifyElsewhere() + "\n\n")
	for i := range items {
		m := &items[i]
		pos := strconv.Itoa(i+1) + " of " + total
		if m.purged {
			b.WriteString("_Exhibit " + pos + " was taken down._\n\n")
			continue
		}
		dest := mediaDestination(m)
		if dest == "" {
			b.WriteString("_Exhibit " + pos + " is not currently available._\n\n")
			continue
		}
		caption := ""
		if m.caption != "" {
			caption = " — " + sanitize.InlineText(m.caption)
		}
		if m.kind == mediaKindVideo {
			b.WriteString("[▶ Exhibit " + pos + caption + "](" + dest +
				") _(a link; the court holds no copy and cannot vouch for it)_\n\n")
			continue
		}
		b.WriteString("![Exhibit " + pos + "](" + dest + ")\n\n")
		b.WriteString("_Exhibit " + pos + caption + "_\n\n")
	}
}
func ClaimMediaPage(courtSlug string, fromID uint64, count int) string {
	c := mustCourt(courtSlug)
	if count < 1 {
		return "[]"
	}
	if count > maxMediaPage {
		count = maxMediaPage
	}
	var b strings.Builder
	b.WriteString("[")
	for i := 0; i < count; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		id := fromID + uint64(i)
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			b.WriteString("[]")
			continue
		}
		b.WriteString(encodeMedia(claimMediaVisible(c, v.(*claimState))))
	}
	b.WriteString("]")
	return b.String()
}
func PurgeClaimMedia(cur realm, courtSlug string, claimID uint64, idx uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if idx >= uint64(len(cs.media)) {
		panic("kourtv2: this claim carries no media item at that position")
	}
	if cs.media[idx].purged {
		return
	}
	fire, votedCode := approveAction(d.pending,
		"mediapurge:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(idx, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	m := &cs.media[idx]
	m.purged = true
	m.sha256 = ""
	m.mirrors = nil
	m.caption = ""
	m.mime = ""
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("media-purge", idx, votedCode), "")
	emitPurge(c.id, claimID, "media-item", who)
}
const (
	maxClaimMediaCount = 7
	maxMirrorsPerItem  = 4
	maxMediaURLLen     = 300
	maxCaptionLen      = 120
	maxMediaBytes = 262144
	maxMediaDim   = 20000
	maxMediaPage = 64
)
const (
	mediaKindImage = "img"
	mediaKindVideo = "vid"
)
type mediaItem struct {
	kind    string
	sha256  string
	mime    string
	w, h    int
	bytes   int
	caption string
	mirrors []string
	purged bool
}
func mediaCharFault(s string) string {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x21 || c > 0x7e {
			return "a mirror is printable ASCII with no spaces"
		}
		switch c {
		case '"', '\'', '<', '>', '(', ')', '\\', ',', '|', '`':
			return "a mirror may not contain " + string(rune(c))
		}
	}
	return ""
}
func isHexLower(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}
func mirrorFault(u string) string {
	if len(u) == 0 || len(u) > maxMediaURLLen {
		return "a mirror is 1.." + strconv.Itoa(maxMediaURLLen) + " characters"
	}
	if fault := mediaCharFault(u); fault != "" {
		return fault
	}
	const scheme = "https://"
	if !strings.HasPrefix(u, scheme) {
		return "a mirror is https — plain http is blocked as mixed content"
	}
	host := u[len(scheme):]
	for _, sep := range []byte{'/', '?', '#'} {
		if i := strings.IndexByte(host, sep); i >= 0 {
			host = host[:i]
		}
	}
	if host == "" {
		return "a mirror needs a host"
	}
	if !mediaHostAllowed(host) {
		return "the browser will not load images from " + host +
			"; see the allowed hosts on the help page"
	}
	return ""
}
var defaultMediaHostsExact = []string{
	"gnolang.github.io",
	"assets.gnoteam.com",
	"sa.gno.services",
	"imgur.com",
	"github.com",
	"imgflip.com",
	"ipfs.io",
	"cloudflare-ipfs.com",
}
var defaultMediaHostSuffixes = []string{
	".imgur.com",
	".github.io",
	".githubusercontent.com",
	".imgflip.com",
}
var mediaHostsExact = appendAll(nil, defaultMediaHostsExact)
var mediaHostSuffixes = appendAll(nil, defaultMediaHostSuffixes)
func appendAll(dst, src []string) []string {
	for _, v := range src {
		dst = append(dst, v)
	}
	return dst
}
const maxMediaHosts = 32
func mediaHostEntryFault(h string, suffix bool) string {
	if h == "" {
		return "a host may not be empty"
	}
	if len(h) > 100 {
		return "a host is at most 100 characters"
	}
	if suffix && h[0] != '.' {
		return "a suffix begins with a dot: " + h
	}
	if !suffix && h[0] == '.' {
		return "an exact host does not begin with a dot: " + h
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'
		if !ok {
			return "a host is lowercase letters, digits, dots and hyphens: " + h
		}
	}
	if strings.Contains(h, "..") || h[len(h)-1] == '.' {
		return "a host has no empty label: " + h
	}
	return ""
}
func parseMediaHosts(list string, suffix bool) []string {
	if strings.TrimSpace(list) == "" {
		return nil
	}
	parts := strings.Split(list, ",")
	if len(parts) > maxMediaHosts {
		panic("kourtv2: at most " + strconv.Itoa(maxMediaHosts) + " hosts in a list")
	}
	out := []string{}
	for _, p := range parts {
		h := strings.TrimSpace(p)
		if fault := mediaHostEntryFault(h, suffix); fault != "" {
			panic("kourtv2: " + fault)
		}
		for _, seen := range out {
			if seen == h {
				panic("kourtv2: " + h + " is listed twice")
			}
		}
		out = append(out, h)
	}
	return out
}
func SetMediaHosts(cur realm, exact, suffixes string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the media hosts")
	}
	ex := parseMediaHosts(exact, false)
	sf := parseMediaHosts(suffixes, true)
	if len(ex) == 0 && len(sf) == 0 {
		panic("kourtv2: to allow no third-party host, call ClearMediaHosts")
	}
	mediaHostsExact = ex
	mediaHostSuffixes = sf
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-media-hosts:"+strconv.Itoa(len(ex))+"+"+strconv.Itoa(len(sf)),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func ClearMediaHosts(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the media hosts")
	}
	mediaHostsExact = nil
	mediaHostSuffixes = nil
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "clear-media-hosts",
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func MediaHosts() string {
	return strings.Join(mediaHostsExact, ",") + "|" + strings.Join(mediaHostSuffixes, ",")
}
func mediaHostAllowed(host string) bool {
	if host == "" {
		return false
	}
	if siteDomain != "" && host == siteDomain && siteDomainFault(siteDomain) == "" {
		return true
	}
	for _, h := range mediaHostsExact {
		if host == h {
			return true
		}
	}
	for _, s := range mediaHostSuffixes {
		if len(host) > len(s) && strings.HasSuffix(host, s) {
			return true
		}
	}
	return false
}
func captionFault(s string) string {
	if runeLen(s) > maxCaptionLen {
		return "a caption is at most " + strconv.Itoa(maxCaptionLen) + " characters"
	}
	for _, r := range s {
		if (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) {
			return "a caption may not contain text-direction controls"
		}
	}
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\n', '\r':
			return "a caption is one line"
		case '|':
			return "a caption may not contain a vertical bar"
		}
		if s[i] < 0x20 && s[i] != '\t' {
			return "a caption may not contain control characters"
		}
	}
	return ""
}
func mediaItemFault(m *mediaItem) string {
	switch m.kind {
	case mediaKindImage:
		if len(m.sha256) != 64 || !isHexLower(m.sha256) {
			return "an image needs a sha256: 64 lowercase hex characters"
		}
		if m.w <= 0 || m.h <= 0 || m.w > maxMediaDim || m.h > maxMediaDim {
			return "an image needs real dimensions"
		}
		if m.bytes <= 0 || m.bytes > maxMediaBytes {
			return "an image is 1.." + strconv.Itoa(maxMediaBytes) + " bytes"
		}
		if m.mime == "" {
			return "an image needs a media type"
		}
	case mediaKindVideo:
		if m.sha256 != "" {
			return "a video link carries no hash"
		}
	default:
		return "a media item is " + mediaKindImage + " or " + mediaKindVideo
	}
	if fault := captionFault(m.caption); fault != "" {
		return fault
	}
	if len(m.mirrors) == 0 {
		return "a media item needs somewhere to find it"
	}
	if len(m.mirrors) > maxMirrorsPerItem {
		return "a media item lists at most " + strconv.Itoa(maxMirrorsPerItem) + " mirrors"
	}
	for _, u := range m.mirrors {
		if fault := mirrorFault(u); fault != "" {
			return fault
		}
	}
	return ""
}
func parseMediaFault(arg string) ([]mediaItem, string) {
	trimmed := strings.TrimSpace(arg)
	if trimmed == "" {
		return nil, ""
	}
	lines := strings.Split(trimmed, "\n")
	if len(lines) > maxClaimMediaCount {
		return nil, "a claim carries at most " +
			strconv.Itoa(maxClaimMediaCount) + " media items"
	}
	out := make([]mediaItem, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		f := strings.Split(line, "|")
		if len(f) != 8 {
			return nil, "a media item has 8 fields separated by |"
		}
		m := mediaItem{
			kind:    f[0],
			sha256:  f[1],
			mime:    f[2],
			w:       atoiOr0(f[3]),
			h:       atoiOr0(f[4]),
			bytes:   atoiOr0(f[5]),
			caption: f[6],
		}
		for _, u := range strings.Split(f[7], ",") {
			if u != "" {
				m.mirrors = append(m.mirrors, u)
			}
		}
		if fault := mediaItemFault(&m); fault != "" {
			return nil, fault
		}
		out = append(out, m)
	}
	return out, ""
}
func parseMediaArg(arg string) []mediaItem {
	items, fault := parseMediaFault(arg)
	if fault != "" {
		panic("kourtv2: " + fault)
	}
	return items
}
func atoiOr0(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}
func jsonString(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0xf])
				continue
			}
			b.WriteByte(c)
		}
	}
	b.WriteString(`"`)
	return b.String()
}
func encodeMedia(items []mediaItem) string {
	if len(items) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteString("[")
	for i := range items {
		if i > 0 {
			b.WriteString(",")
		}
		m := &items[i]
		b.WriteString(`{"kind":`)
		b.WriteString(jsonString(m.kind))
		if m.purged {
			b.WriteString(`,"purged":true}`)
			continue
		}
		b.WriteString(`,"sha256":`)
		b.WriteString(jsonString(m.sha256))
		b.WriteString(`,"mime":`)
		b.WriteString(jsonString(m.mime))
		b.WriteString(`,"w":`)
		b.WriteString(strconv.Itoa(m.w))
		b.WriteString(`,"h":`)
		b.WriteString(strconv.Itoa(m.h))
		b.WriteString(`,"bytes":`)
		b.WriteString(strconv.Itoa(m.bytes))
		b.WriteString(`,"caption":`)
		b.WriteString(jsonString(m.caption))
		b.WriteString(`,"mirrors":[`)
		n := 0
		for _, u := range m.mirrors {
			if mirrorFault(u) != "" {
				continue
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(jsonString(u))
			n++
		}
		b.WriteString(`]}`)
	}
	b.WriteString("]")
	return b.String()
}
