package memba_blog_v1

// memba_blog_v1 — the on-chain Memba blog (backlog item 8).
//
// The Memba /blog is a build-time static pipeline today; this realm makes the
// published articles chain-native while the frontend keeps its /blog/<slug>
// URLs (slugs are the stable key). Design constraints:
//
//   - FUNDS-FREE. No banker import, no OriginSend read anywhere — nothing to
//     drain, trivially passes the mainnet fund-safety gate.
//   - Editor-gated writes: the admin (samcrew 2-of-2 multisig) manages an
//     editors allowlist; only admin/editors publish. Everything else is read.
//   - Honest permanence: posts are never erased — Unpublish flips visibility
//     (readers stop listing it) but the revision history stays on-chain.
//   - Bounded reads: paged meta getters (JSON — titles are free text, so the
//     pipe-row format used by the market getters is not injection-safe here),
//     body fetched per-slug.

import (
	"strings"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// AdminAddress is the samcrew-core 2-of-2 multisig (same admin as the fee
// spine and the app store).
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// MaxBodyBytes bounds one article (64 KiB of markdown is a very long post;
	// the bound exists so a compromised editor key can't bloat realm storage).
	MaxBodyBytes = 64 * 1024
	MaxTitleLen  = 200
	MaxSlugLen   = 100
	MaxTagsLen   = 200
	// MaxPageLimit bounds one meta page (gas/DoS surface).
	MaxPageLimit = 50
)

// Post is one article. Body is raw markdown; the frontend renders it with the
// same renderer as the static pipeline. CreatedBlk/UpdatedBlk are BLOCK
// HEIGHTS (chain-native timestamps), resolved to dates client-side.
type Post struct {
	Slug       string
	Title      string
	Author     address // the editor who published it
	Tags       string  // comma-separated, display-only
	Date       string  // editorial date YYYY-MM-DD (migration keeps original dates)
	Body       string
	CreatedBlk int64
	UpdatedBlk int64
	Published  bool
}

var (
	posts     *avl.Tree // slug -> *Post
	postOrder []string  // insertion-ordered slugs (stable pagination)
	editors   *avl.Tree // address string -> true
)

func init() {
	posts = avl.NewTree()
	editors = avl.NewTree()
}

// ── Auth ──────────────────────────────────────────────────────────────────────

func assertAdmin() {
	if unsafe.PreviousRealm().Address() != address(AdminAddress) {
		panic("admin only")
	}
}

func assertEditor() {
	caller := unsafe.PreviousRealm().Address()
	if caller == address(AdminAddress) {
		return
	}
	if editors.Has(caller.String()) {
		return
	}
	panic("editor only")
}

// AddEditor allowlists an address for publishing. Admin-only.
func AddEditor(cur realm, addrStr string) {
	assertAdmin()
	if addrStr == "" {
		panic("empty address")
	}
	editors.Set(addrStr, true)
	chain.Emit("EditorAdded", "addr", addrStr)
}

// RemoveEditor revokes publishing rights. Admin-only.
func RemoveEditor(cur realm, addrStr string) {
	assertAdmin()
	editors.Remove(addrStr)
	chain.Emit("EditorRemoved", "addr", addrStr)
}

// ── Validation ────────────────────────────────────────────────────────────────

// validSlug enforces the exact shape the frontend's /blog/<slug> routes use:
// lowercase kebab-case, no leading/trailing/double hyphen.
func validSlug(s string) bool {
	if s == "" || len(s) > MaxSlugLen {
		return false
	}
	prev := byte('-')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			prev = c
		case c == '-':
			if prev == '-' {
				return false // leading or doubled hyphen
			}
			prev = c
		default:
			return false
		}
	}
	return s[len(s)-1] != '-'
}

// validDate accepts exactly YYYY-MM-DD (display/sort fidelity for migrated
// articles; block heights are recorded separately for chain-native ordering).
func validDate(d string) bool {
	if len(d) != 10 || d[4] != '-' || d[7] != '-' {
		return false
	}
	for i, c := range []byte(d) {
		if i == 4 || i == 7 {
			continue
		}
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func validateContent(title, tags, body string) {
	if strings.TrimSpace(title) == "" || len(title) > MaxTitleLen {
		panic("invalid title")
	}
	if len(tags) > MaxTagsLen {
		panic("tags too long")
	}
	if strings.TrimSpace(body) == "" {
		panic("empty body")
	}
	if len(body) > MaxBodyBytes {
		panic("body too large")
	}
}

// ── Writes (editor-gated) ─────────────────────────────────────────────────────

// PublishPost publishes a new article under a stable slug.
func PublishPost(cur realm, slug, title, tags, date, body string) {
	assertEditor()
	if !validSlug(slug) {
		panic("invalid slug (lowercase kebab-case)")
	}
	if _, dup := posts.Get(slug); dup {
		panic("slug already exists")
	}
	if !validDate(date) {
		panic("invalid date (YYYY-MM-DD)")
	}
	validateContent(title, tags, body)
	h := runtime.ChainHeight()
	posts.Set(slug, &Post{
		Slug:       slug,
		Title:      title,
		Author:     unsafe.PreviousRealm().Address(),
		Tags:       tags,
		Date:       date,
		Body:       body,
		CreatedBlk: h,
		UpdatedBlk: h,
		Published:  true,
	})
	postOrder = append(postOrder, slug)
	chain.Emit("PostPublished", "slug", slug)
}

// UpdatePost revises an existing article in place (same slug — URLs stay
// stable). The revision height is recorded; prior content stays in chain
// history by nature.
func UpdatePost(cur realm, slug, title, tags, date, body string) {
	assertEditor()
	v, ok := posts.Get(slug)
	if !ok {
		panic("unknown slug")
	}
	if !validDate(date) {
		panic("invalid date (YYYY-MM-DD)")
	}
	validateContent(title, tags, body)
	p := v.(*Post)
	p.Title = title
	p.Tags = tags
	p.Date = date
	p.Body = body
	p.UpdatedBlk = runtime.ChainHeight()
	chain.Emit("PostUpdated", "slug", slug)
}

// SetPublished flips an article's visibility (readers stop listing it; the
// content itself is on-chain forever — that is disclosed, not hidden).
func SetPublished(cur realm, slug string, published bool) {
	assertEditor()
	v, ok := posts.Get(slug)
	if !ok {
		panic("unknown slug")
	}
	p := v.(*Post)
	p.Published = published
	p.UpdatedBlk = runtime.ChainHeight()
	if published {
		chain.Emit("PostRepublished", "slug", slug)
	} else {
		chain.Emit("PostUnpublished", "slug", slug)
	}
}

// ── Reads (pure, non-failing) ─────────────────────────────────────────────────

// PostCount returns the number of PUBLISHED posts.
func PostCount() int {
	n := 0
	for _, slug := range postOrder {
		if v, ok := posts.Get(slug); ok && v.(*Post).Published {
			n++
		}
	}
	return n
}

// GetPostsPage returns a JSON array of published post META (no bodies),
// newest-first, windowed by offset/limit (limit clamped to [1, MaxPageLimit]).
// JSON because titles/tags are editor free text — a delimited row format
// would be injectable.
func GetPostsPage(offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPageLimit {
		limit = MaxPageLimit
	}
	// newest-first = reverse insertion order, published only
	published := []*Post{}
	for i := len(postOrder) - 1; i >= 0; i-- {
		if v, ok := posts.Get(postOrder[i]); ok {
			if p := v.(*Post); p.Published {
				published = append(published, p)
			}
		}
	}
	var sb strings.Builder
	sb.WriteString("[")
	wrote := 0
	for i := offset; i < len(published) && wrote < limit; i++ {
		if wrote > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(postMetaJSON(published[i]))
		wrote++
	}
	sb.WriteString("]")
	return sb.String()
}

// GetPostJSON returns one published post as JSON INCLUDING the body, or ""
// when the slug is unknown or unpublished (non-failing read).
func GetPostJSON(slug string) string {
	v, ok := posts.Get(slug)
	if !ok {
		return ""
	}
	p := v.(*Post)
	if !p.Published {
		return ""
	}
	meta := postMetaJSON(p)
	// splice the body into the meta object
	return meta[:len(meta)-1] + `,"body":"` + jsonEscape(p.Body) + `"}`
}

func postMetaJSON(p *Post) string {
	return ufmt.Sprintf(
		`{"slug":"%s","title":"%s","author":"%s","tags":"%s","date":"%s","createdBlk":%d,"updatedBlk":%d}`,
		jsonEscape(p.Slug), jsonEscape(p.Title), p.Author.String(), jsonEscape(p.Tags),
		jsonEscape(p.Date), p.CreatedBlk, p.UpdatedBlk,
	)
}

// jsonEscape escapes a string for embedding in a JSON string literal (same
// helper as memba_appstore_v3 — editor text is still untrusted input on the
// read path).
func jsonEscape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if r < 0x20 {
				sb.WriteString(ufmt.Sprintf("\\u%04x", r))
			} else {
				sb.WriteString(string(r))
			}
		}
	}
	return sb.String()
}

// ── Render ────────────────────────────────────────────────────────────────────

func Render(path string) string {
	if path != "" {
		if v, ok := posts.Get(path); ok {
			p := v.(*Post)
			if p.Published {
				return ufmt.Sprintf("# %s\n\n_%s · by %s_\n\n%s\n",
					p.Title, p.Date, p.Author.String(), p.Body)
			}
		}
		return "post not found\n"
	}
	var sb strings.Builder
	sb.WriteString("# Memba Blog\n\n")
	sb.WriteString(ufmt.Sprintf("**%d published posts**\n\n", PostCount()))
	for i := len(postOrder) - 1; i >= 0; i-- {
		if v, ok := posts.Get(postOrder[i]); ok {
			p := v.(*Post)
			if p.Published {
				sb.WriteString(ufmt.Sprintf("- [%s](/r/samcrew/memba_blog_v1:%s) · %s\n",
					p.Title, p.Slug, p.Date))
			}
		}
	}
	return sb.String()
}
