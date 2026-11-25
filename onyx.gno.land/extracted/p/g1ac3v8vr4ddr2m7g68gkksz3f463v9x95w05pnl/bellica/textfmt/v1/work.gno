package textfmt

import (
	"strings"
)

// Categories (fixed list). Empty input means "other".
var Categories = []string{"code", "design", "image", "video", "audio", "writing", "data", "research", "other"}

// Deliverable kinds.
var deliverKinds = []string{"link", "image", "video", "file", "text", "repo"}

const MaxDeliverText = 2000 // bytes, kind "text"

const maxDeliverLines = 40

func InList(s string, list []string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// mustCategory normalizes and validates a category ("" -> "other").
func MustCategory(c string) string {
	c = strings.ToLower(Clean(c))
	if c == "" {
		return "other"
	}
	if !InList(c, Categories) {
		panic("unknown category: use one of " + strings.Join(Categories, ", "))
	}
	return c
}

// subjective categories are scored by the judge's assessment, not a metric.
func Subjective(c string) bool {
	switch c {
	case "design", "image", "video", "audio", "writing":
		return true
	}
	return false
}

func ScoringOf(c string) string {
	if Subjective(c) {
		return "judge"
	}
	return "metric"
}

// mustWorkURL accepts only https:// (with a real host, no userinfo) or
// ipfs://<cid>[/path], at most MaxURL bytes, without characters that can
// break markdown links or HTML attributes (AUDIT H1).
func MustWorkURL(field, u string) string {
	u = Clean(u)
	MustLen(field, u, 10, MaxURL)
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
	h = strings.ToLower(Clean(h))
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
	return Clean(s)
}

// mustDeliverable validates a deliverable and returns its normalized parts.
// kind "text" carries text (URL optional); every other kind needs a URL and no text.
func MustDeliverable(kind, url, hash, text string) (string, string, string, string) {
	kind = strings.ToLower(Clean(kind))
	if !InList(kind, deliverKinds) {
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
		if Clean(url) != "" {
			url = MustWorkURL("url", url)
		} else {
			url = ""
		}
		return kind, url, hash, text
	}
	if text != "" {
		panic("text is only for kind text; link the file instead")
	}
	return kind, MustWorkURL("url", url), hash, ""
}

func KindIcon(k string) string {
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

func CatLabel(c string) string { return catIcon(c) + " " + c }

// workLink renders a stored work URL. https links become markdown links with
// the full host visible (AUDIT F6); ipfs:// links point at a public gateway.
func WorkLink(u string) string {
	if strings.HasPrefix(u, "ipfs://") {
		rest := u[len("ipfs://"):]
		label := rest
		if r := []rune(label); len(r) > 24 {
			label = string(r[:23]) + "…"
		}
		return "[ipfs://" + Esc(label) + "](https://ipfs.io/ipfs/" + rest + ")"
	}
	return Link(u)
}

// deliverableLine renders kind + link + hash (+ commit for repos).
func DeliverableLine(kind, url, hash, commit string) string {
	s := KindIcon(kind) + " " + Esc(kind)
	if url != "" {
		s += " · " + WorkLink(url)
	}
	if commit != "" {
		s += " @ `" + Esc(shortCommit(commit)) + "`"
	}
	if hash != "" {
		s += " · sha256 `" + hash[:12] + "…`"
	}
	return s
}

// quoteText renders multi-line user text as an escaped blockquote. Every line
// is escaped, and line starts that markdown would read as a list, rule or
// setext heading are escaped too (AUDIT H2).
func QuoteText(t string) string {
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
	out := Esc(line)
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
		out = line[:i] + "\\" + Esc(line[i:])
	}
	return out
}
