package tutorials

import (
	"std"
	"strings"
	"time"

	"gno.land/p/demo/mux"
	"gno.land/p/ecodevx/blog"
)

func Render(path string) string {
	router := mux.NewRouter()
	router.NotFoundHandler = func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("Path not found")
	}

	router.HandleFunc("", renderBlog)
	router.HandleFunc("posts", renderBlog)
	router.HandleFunc("posts/{slug}", renderPost)
	router.HandleFunc("drafts", renderDrafts)
	router.HandleFunc("revisions", renderRevisions)
	router.HandleFunc("tags", renderTags)
	router.HandleFunc("tags/{name}", renderPostsByTag)
	router.HandleFunc("params", renderParams)

	return renderAlerts() + router.Render(path)
}

// GetTutorialsBlog returns an invariant reference to the tutorials blog.
func GetTutorialsBlog() blog.InvarBlog {
	return blog.NewInvarBlog(&tutorialsBlog)
}

// TutorialExists checks if a tutorial with a specific slug exists.
func TutorialExists(slug string) bool {
	return tutorialsBlog.HasPost(slug)
}

// Publish publishes content for a tutorial.
//
// The submited content must be previously approved by a creation or modification proposal.
//
// Parameters:
// - slug: Slug name of the tutorial (required)
// - content: The tutorial content to publish (required)
func Publish(slug, content string) {
	assertRealmIsNotLocked()

	// Check that content checksum matches the approved content for the tutorial post
	p := mustGetPost(slug)
	blog.AssertContentSha256Hash(content, p.ContentHash)

	// Remove content metadata if present
	// TODO: Use front matter JSON metadata to init optional post fields?
	_, content = extractFrontMatter(content)

	// Add caller to the list of publishers
	caller := std.GetOrigCaller()
	if !p.Publishers.HasAddress(caller) {
		p.Publishers = append(p.Publishers, caller)
	}

	if p.Status == blog.StatusDraft {
		p.PublishAt = time.Now()
	}

	p.Status = blog.StatusPublished
	p.Content = content
	p.UpdatedAt = time.Now()
}

func extractFrontMatter(content string) (meta, body string) {
	// Front matter is defined at the start of the Markdown content, surrounded by "---"
	s, hasMeta := strings.CutPrefix(content, "---\n")
	if !hasMeta {
		return "", content
	}

	// Split front matter metadata and Markdown content
	meta, body, _ = strings.Cut(s, "---\n")
	return strings.TrimSpace(meta), body
}
