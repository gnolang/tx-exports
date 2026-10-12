package definition

import (
	"net/url"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderSearchAndEscaping(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	key := "한글\"<&[key] & ? :"
	setTestDefinition(cross(cur), key, []Field{
		{"text", "한글\n```\n<script>alert(1)</script>\n**bold**"},
		{"link", "https://example.com/a(b)?x=1&y=2"},
		{"unsafe", "javascript:alert(1)"},
		{"mixed", "https://example.com/ text"},
		{"empty", ""},
	})
	page := Render("")
	uassert.True(t, strings.Contains(page, "<gno-form path=\"search\">"))
	uassert.True(t, strings.Contains(page, "name=\"key\""))
	uassert.False(t, strings.Contains(page, "name=\"type\""))
	uassert.True(t, strings.Contains(page, "search?key="+url.QueryEscape(key)))
	result := Render("search?key=" + url.QueryEscape(key) + "&page=2")
	uassert.True(t, strings.Contains(result, "value=\"한글&#34;&lt;&amp;[key] &amp; ? :\""))
	uassert.True(t, strings.Contains(result, "[Back to list](./definition:list?page=2)"))
	uassert.True(t, strings.Contains(result, "````\n한글\n```\n<script>alert(1)</script>\n**bold**\n````"))
	uassert.True(t, strings.Contains(result, "](<https://example.com/a(b)?x=1&y=2>)"))
	uassert.True(t, strings.Contains(result, "```\njavascript:alert(1)\n```"))
	uassert.True(t, strings.Contains(result, "```\nhttps://example.com/ text\n```"))
	for _, tc := range []struct{ path, message string }{
		{"search", "Key is required"}, {"search?key=missing", "Entry not found"},
		{"list?page=0", "Invalid page"}, {"?page=999999999999999999999999", "Invalid page"},
		{"?key=%zz", "Invalid query"}, {"other", "Page not found"},
	} {
		result := Render(tc.path)
		uassert.True(t, strings.Contains(result, tc.message))
		uassert.True(t, strings.Contains(result, "<gno-form path=\"search\">"))
	}
	uassert.True(t, strings.Contains(Render("search?key=missing"), "value=\"missing\""))
}

func TestRenderPagination(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	uassert.True(t, strings.Contains(Render(""), "No entries"))
	batch := []testEntry{}
	for i := 100; i < 141; i++ {
		batch = append(batch, testEntry{strconv.Itoa(i), []Field{{"key", "item_" + strconv.Itoa(i)}}})
	}
	setTestDefinitions(cross(cur), batch)
	for _, tc := range []struct {
		page, count    int
		previous, next bool
	}{
		{1, 20, false, true}, {2, 20, true, true}, {3, 1, true, false}, {4, 0, true, false},
	} {
		page := Render("list?page=" + strconv.Itoa(tc.page))
		uassert.Equal(t, tc.count, strings.Count(page, "./definition:search?key="))
		uassert.Equal(t, tc.previous, strings.Contains(page, "[Previous]"))
		uassert.Equal(t, tc.next, strings.Contains(page, "[Next]"))
		uassert.True(t, strings.Contains(page, "Page "+strconv.Itoa(tc.page)+" / 3"))
	}
	first := Render("")
	uassert.True(t, strings.Contains(first, "* [100 — item\\_100](./definition:search?key=100&page=1)"))
	uassert.True(t, strings.Contains(first, "search?key=119&page=1"))
	uassert.False(t, strings.Contains(first, "search?key=120"))
	uassert.False(t, strings.Contains(Render("list?page=9223372036854775807"), "[Next]"))
}

func TestRenderReadableHeadings(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	SetDefinitions(cross(cur), "1103015", "abilities=value&displayMetadata=value&key=wooden_sword")
	page := Render("search?key=1103015&page=10")
	uassert.True(t, strings.Contains(page, "## 1103015\n"))
	uassert.True(t, strings.Contains(page, "### abilities\n"))
	uassert.True(t, strings.Contains(page, "### displayMetadata\n"))
	uassert.False(t, strings.Contains(page, "&#"))
	uassert.True(t, strings.Contains(Render(""), "[1103015 — wooden\\_sword]"))
	// Literal entities and markup must remain text, including in the TOC.
	uassert.Equal(t, `\&\#49\; \<script\> \[x\]\(url\) \*bold\* \~strike\~`, renderLabel("&#49; <script> [x](url) *bold* ~strike~"))
	uassert.Equal(t, "한글 😀 next line", renderLabel("한글 😀\nnext\rline"))
}

func TestRenderNumericPageOrder(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	entries := []testEntry{}
	for i := 21; i >= 0; i-- {
		entries = append(entries, testEntry{strconv.Itoa(i), []Field{{"name", "item"}}})
	}
	setTestDefinitions(cross(cur), entries)
	first := Render("")
	previous := -1
	for i := 0; i < 20; i++ {
		position := strings.Index(first, "](./definition:search?key="+strconv.Itoa(i)+"&page=1)")
		uassert.True(t, position > previous)
		previous = position
	}
	uassert.False(t, strings.Contains(first, "search?key=20&"))
	second := Render("list?page=2")
	uassert.Equal(t, 2, strings.Count(second, "](./definition:search?key="))
	uassert.True(t, strings.Contains(second, "search?key=20&page=2"))
	uassert.True(t, strings.Contains(second, "search?key=21&page=2"))
}
