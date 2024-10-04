package space

import (
	"std"
	"strings"
	"time"

	"gno.land/p/demo/mux"
	"gno.land/p/ecodevx/blog"
)

const minTitleLen = 6

func Render(path string) string {
	r := mux.NewRouter()
	r.NotFoundHandler = func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("Path not found")
	}

	r.HandleFunc("", renderHome)
	r.HandleFunc("news", renderNews)
	r.HandleFunc("news/{tag}", renderNewsByTag)
	r.HandleFunc("section/{slug}", renderDataSection)
	r.HandleFunc("section/{slug}/{tag}", renderDataSectionByTag)
	r.HandleFunc("content/{sectionSlug}/{contentSlug}", renderContent)
	r.HandleFunc("datasources", renderDatasources)
	r.HandleFunc("params", renderParams)

	r.HandleFunc("terms-and-conditions", func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(termsAndConditions)
	})
	r.HandleFunc("privacy-policy", func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write(privacyPolicy)
	})

	return renderAlerts() + r.Render(path)
}

// IterateEditors iterates editor accounts.
func IterateEditors(fn func(std.Address) bool) {
	for _, e := range editors {
		if fn(e) {
			return
		}
	}
}

// IterateTools iterates invariant references of Gnome space tools.
func IterateTools(fn func(InvarTool) bool) {
	for _, t := range tools {
		if fn(newInvarTool(t)) {
			return
		}
	}
}

// IterateLinks iterates invariant references of Gnome space links.
func IterateLinks(fn func(section string, _ InvarLink) bool) {
	indexes.Link.Iterate(func(s Section, l *Link) bool {
		return fn(string(s), newInvarLink(l))
	})
}

// IterateNews iterates invariant references of Gnome space news.
func IterateNews(fn func(InvarNews) bool) {
	indexes.News.Iterate(func(n *News) bool {
		return fn(newInvarNews(n))
	})
}

// IterateDataSections iterates invariant references of Gnome space data sections.
func IterateDataSections(fn func(InvarDataSection) bool) {
	indexes.DataSection.Iterate(func(s *DataSection) bool {
		return fn(newInvarDataSection(s))
	})
}

// CreateNews creates a news entry.
//
// Only editors are allowed to create news.
//
// Parameters:
// - title: A title for the news entry (required)
// - url: URL with the link to the news content (required)
// - tags: Comma separated list of tags for the news entry (required)
func CreateNews(title, url, tags string) uint64 {
	assertRealmIsNotLocked()
	assertOrigCallerIsEditor()

	title = strings.TrimSpace(title)
	assertNewsTitleLength(title)
	assertValidURL(url)

	id := genNewsID()
	indexes.News.Index(&News{
		ID:        id,
		Title:     title,
		URL:       url,
		Tags:      mustParseStringToTags(tags),
		CreatedAt: time.Now(),
	})
	return uint64(id)
}

// UpdateNews updates a news entry.
//
// Only editors are allowed to update news.
//
// Parameters:
// - newsID: ID of the news entry to update (required)
// - title: A title for the news entry
// - url: URL with the link to the news content
// - tags: Comma separated list of tags for the news entry
func UpdateNews(newsID uint64, title, url, tags string) {
	assertRealmIsNotLocked()
	assertOrigCallerIsEditor()

	n, found := indexes.News.GetByID(ID(newsID))
	if !found {
		panic("news not found")
	}

	title = strings.TrimSpace(title)
	if title != "" {
		assertNewsTitleLength(title)
		n.Title = title
	}

	url = strings.TrimSpace(url)
	if url != "" {
		assertValidURL(url)
		n.URL = url
	}

	tags = strings.TrimSpace(tags)
	if tags != "" {
		n.Tags = mustParseStringToTags(tags)
	}
}

// DeleteNews deletes a news entry.
//
// Only editors are allowed to delete news.
//
// Parameters:
// - newsID: ID of the news entry to delete (required)
func DeleteNews(newsID uint64) {
	assertRealmIsNotLocked()
	assertOrigCallerIsEditor()

	if !indexes.News.Remove(ID(newsID)) {
		panic("news not found")
	}
}

// DisableDataSection disabled or enables a data section.
// Data sections are sections where the data displayed in that section comes from another realm.
//
// Only editors are allowed to disable or enable data sections.
//
// Parameters:
// - sectionSlug: Slug of the section.
// - disable: Toggle disabled or enabled data sections.
func DisableDataSection(sectionSlug string, disable bool) {
	assertRealmIsNotLocked()
	assertOrigCallerIsEditor()

	section, found := indexes.DataSection.GetBySlug(sectionSlug)
	if !found {
		panic("data section not found")
	}

	section.Disabled = disable
}

func mustParseStringToTags(s string) (tags []string) {
	for _, v := range strings.Split(s, ",") {
		tag := strings.TrimSpace(v)
		assertIsTag(tag)
		tags = append(tags, tag)
	}
	return
}

func assertOrigCallerIsEditor() {
	caller := std.GetOrigCaller()
	assertIsEditor(caller)
}

func assertIsTag(tag string) {
	if !blog.IsSlug(tag) {
		panic("invalid tag: " + tag)
	}
}

func assertValidURL(url string) {
	if !blog.IsURL(url, false) {
		panic("URL is not valid")
	}
}

func assertNewsTitleLength(title string) {
	if len(title) < minTitleLen {
		panic("title is too short")
	}
}
