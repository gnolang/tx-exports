package memba_notes_rc1

import (
	"strconv"
	"strings"
)

// gnoweb uses bounded pages. A revision in every continuation link prevents
// assembling a whitepaper from different edits; the app reads binary chunks.
func Render(path string) string {
	if path == "" {
		return "# Notes\n\nUse ListPublicJSON for the public directory.\n"
	}
	if len(path) > 80 {
		panic("notes: render path")
	}
	parts := strings.Split(path, "/")
	if len(parts) != 1 && len(parts) != 3 {
		panic("notes: render path")
	}
	n := find(readID(parts[0]))
	if n.Deleted {
		return "# Deleted note\n\nPast versions remain in chain history.\n"
	}
	page := 0
	if len(parts) == 3 {
		rev, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil || rev != n.Revision {
			return "# Note changed\n\n[Start again](:" + idText(n.ID) + ").\n"
		}
		page, err = strconv.Atoi(parts[2])
		if err != nil {
			panic("notes: render page")
		}
	}
	if !public(n.Mode) {
		return "# Encrypted note\n\n" + seal(n.Body) + "\nOwner: " + string(n.Owner) + "\n\nEncrypted bytes: " + strconv.Itoa(n.BodyBytes) + " · Revision " + strconv.FormatUint(n.Revision, 10) + "\n\nOpen this note in Memba to decrypt. This seal is decorative.\n"
	}
	pages := (n.BodyBytes + MaxBodyChunkBytes - 1) / MaxBodyChunkBytes
	if pages == 0 {
		pages = 1
	}
	if page < 0 || page >= pages {
		panic("notes: render page")
	}
	start := renderBoundary(n.Body, page*MaxBodyChunkBytes)
	end := renderBoundary(n.Body, (page+1)*MaxBodyChunkBytes)
	title := strings.NewReplacer("\\", "\\\\", "[", "\\[", "]", "\\]", "*", "\\*", "_", "\\_", "`", "\\`", "#", "\\#", "<", "&lt;", ">", "&gt;").Replace(string(n.Title))
	body := strings.ReplaceAll(strings.ReplaceAll(string(n.Body[start:end]), "<", "&lt;"), ">", "&gt;")
	// Entity tokens are text, not Markdown image syntax, even after a backslash.
	// Keep ordinary links available without automatically fetching remote images.
	body = strings.ReplaceAll(body, "![", "&#33;[")
	nav := ""
	if pages > 1 {
		nav = "\n\n---\n\nPage " + strconv.Itoa(page+1) + " of " + strconv.Itoa(pages) + " · " + strconv.Itoa(n.BodyBytes) + " bytes · revision " + strconv.FormatUint(n.Revision, 10) + ". Markdown may continue across pages.\n\n"
		base := ":" + idText(n.ID) + "/" + strconv.FormatUint(n.Revision, 10) + "/"
		if page > 0 {
			nav += "[Previous](" + base + strconv.Itoa(page-1) + ") "
		}
		if page+1 < pages {
			nav += "[Next](" + base + strconv.Itoa(page+1) + ") "
		}
		nav += "[Read the complete note in Memba](https://memba.club/os/notes/" + idText(n.ID) + ")\n"
	}
	return "# " + title + "\n\n" + body + nav
}

// Advance at most three continuation bytes; adjacent pages use the same
// boundary, so no UTF8 byte is lost or repeated.
func renderBoundary(body []byte, pos int) int {
	if pos >= len(body) {
		return len(body)
	}
	for pos < len(body) && body[pos]&0xc0 == 0x80 {
		pos++
	}
	return pos
}
