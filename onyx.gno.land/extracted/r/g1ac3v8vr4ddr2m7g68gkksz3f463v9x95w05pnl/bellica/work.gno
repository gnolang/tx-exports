package bellica

import (
	"strings"
)

// Any kind of work: categories, deliverables and their validation.
// Files never live on-chain: a deliverable is a kind + an https:// or ipfs://
// URL + an optional sha256 of the content + a short note (or, for kind
// "text", up to 2,000 characters of text).

// Categories (fixed list). Empty input means "other".
var categories = []string{"code", "design", "image", "video", "audio", "writing", "data", "research", "other"}

// Deliverable kinds.
var deliverKinds = []string{"link", "image", "video", "file", "text", "repo"}

const (
	MaxDeliverText  = 2000 // bytes, kind "text"
	maxDeliverLines = 40
)

func inList(s string, list []string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// mustCategory normalizes and validates a category ("" -> "other").
func mustCategory(c string) string {
	c = strings.ToLower(clean(c))
	if c == "" {
		return "other"
	}
	if !inList(c, categories) {
		panic("unknown category: use one of " + strings.Join(categories, ", "))
	}
	return c
}

// subjective categories are scored by the judge's assessment, not a metric.
func subjective(c string) bool {
	switch c {
	case "design", "image", "video", "audio", "writing":
		return true
	}
	return false
}

func scoringOf(c string) string {
	if subjective(c) {
		return "judge"
	}
	return "metric"
}

// mustWorkURL accepts only https:// (with a real host, no userinfo) or
// ipfs://<cid>[/path], at most MaxURL bytes, without characters that can
// break markdown links or HTML attributes (AUDIT H1).
func mustWorkURL(field, u string) string {
	u = clean(u)
	mustLen(field, u, 10, MaxURL)
	if strings.ContainsAny(u, " ()<>[]{}\"'`|\\^") {
		panic(field + " contains characters that are not allowed in a URL")
	}
	switch {
	case strings.HasPrefix(u, "https://"):
		rest := u[len("https://"):]
		host := rest
		if i := strings.IndexAny(rest, "/?#"); i >= 0 {
			host = rest[:i]
		}
		if host == "" || strings.Contains(host, "@") || !strings.Contains(host, ".") && host != "localhost" {
			panic(field + " needs a valid https host")
		}
	case strings.HasPrefix(u, "ipfs://"):
		rest := u[len("ipfs://"):]
		cid := rest
		if i := strings.Index(rest, "/"); i >= 0 {
			cid = rest[:i]
		}
		if len(cid) < 10 || !alnum(cid) {
			panic(field + " needs a valid ipfs CID")
		}
	default:
		panic(field + " must start with https:// or ipfs://")
	}
	return u
}

func alnum(s string) bool {
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z') {
			return false
		}
	}
	return true
}

// mustHash accepts "" or a sha256 hex digest (optionally "sha256:"-prefixed), stored lowercase.
func mustHash(h string) string {
	h = strings.ToLower(clean(h))
	h = strings.TrimPrefix(h, "sha256:")
	if h == "" {
		return ""
	}
	if len(h) != 64 {
		panic("sha256 must be 64 hex characters")
	}
	for _, r := range h {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			panic("sha256 must be 64 hex characters")
		}
	}
	return h
}

// cleanText is clean() for multi-line text: line breaks are kept (as \n),
// everything else clean() drops is dropped.
func cleanText(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return clean(s)
}

// mustDeliverable validates a deliverable and returns its normalized parts.
// kind "text" carries text (URL optional); every other kind needs a URL and no text.
func mustDeliverable(kind, url, hash, text string) (string, string, string, string) {
	kind = strings.ToLower(clean(kind))
	if !inList(kind, deliverKinds) {
		panic("unknown deliverable kind: use one of " + strings.Join(deliverKinds, ", "))
	}
	hash = mustHash(hash)
	text = cleanText(text)
	if kind == "text" {
		if len(text) < 1 || len(text) > MaxDeliverText {
			panic("text must be 1-2000 characters")
		}
		if strings.Count(text, "\n") >= maxDeliverLines {
			panic("text must be at most 40 lines")
		}
		if clean(url) != "" {
			url = mustWorkURL("url", url)
		} else {
			url = ""
		}
		return kind, url, hash, text
	}
	if text != "" {
		panic("text is only for kind text; link the file instead")
	}
	return kind, mustWorkURL("url", url), hash, ""
}

// ---------- rendering ----------

func kindIcon(k string) string {
	switch k {
	case "image":
		return "🖼️"
	case "video":
		return "🎬"
	case "file":
		return "📄"
	case "text":
		return "📝"
	case "repo":
		return "💻"
	}
	return "🔗"
}

func catIcon(c string) string {
	switch c {
	case "code":
		return "💻"
	case "design":
		return "🎨"
	case "image":
		return "🖼️"
	case "video":
		return "🎬"
	case "audio":
		return "🎧"
	case "writing":
		return "✍️"
	case "data":
		return "📊"
	case "research":
		return "🔬"
	}
	return "🧩"
}

func catLabel(c string) string { return catIcon(c) + " " + c }

// workLink renders a stored work URL. https links become markdown links with
// the full host visible (AUDIT F6); ipfs:// links point at a public gateway.
func workLink(u string) string {
	if strings.HasPrefix(u, "ipfs://") {
		rest := u[len("ipfs://"):]
		label := rest
		if r := []rune(label); len(r) > 24 {
			label = string(r[:23]) + "…"
		}
		return "[ipfs://" + esc(label) + "](https://ipfs.io/ipfs/" + rest + ")"
	}
	return link(u)
}

// deliverableLine renders kind + link + hash (+ commit for repos).
func deliverableLine(kind, url, hash, commit string) string {
	s := kindIcon(kind) + " " + esc(kind)
	if url != "" {
		s += " · " + workLink(url)
	}
	if commit != "" {
		s += " @ `" + esc(shortCommit(commit)) + "`"
	}
	if hash != "" {
		s += " · sha256 `" + hash[:12] + "…`"
	}
	return s
}

// quoteText renders multi-line user text as an escaped blockquote. Every line
// is escaped, and line starts that markdown would read as a list, rule or
// setext heading are escaped too (AUDIT H2).
func quoteText(t string) string {
	var sb strings.Builder
	for _, line := range strings.Split(t, "\n") {
		sb.WriteString("> " + escLine(line) + "\n")
	}
	return sb.String()
}

func escLine(line string) string {
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	out := esc(line)
	switch line[0] {
	case '-', '+', '=', '.':
		out = "\\" + out
	}
	// "1." / "1)" ordered-list starts
	i := 0
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		i++
	}
	if i > 0 && i < len(line) && (line[i] == '.' || line[i] == ')') {
		out = line[:i] + "\\" + esc(line[i:])
	}
	return out
}

// catFilter renders a row of category filter links for a page prefix ("cat/" or "jobs/").
func catFilter(prefix, all, cur string) string {
	var sb strings.Builder
	sb.WriteString("Filter: ")
	if cur == "" {
		sb.WriteString("**all**")
	} else {
		sb.WriteString("[all](" + pl(all) + ")")
	}
	for _, c := range categories {
		sb.WriteString(" · ")
		if c == cur {
			sb.WriteString("**" + catLabel(c) + "**")
		} else {
			sb.WriteString("[" + catLabel(c) + "](" + pl(prefix+c) + ")")
		}
	}
	return sb.String() + "\n\n"
}
