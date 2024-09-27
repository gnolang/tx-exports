package tutorials

import (
	"strings"
	"time"

	"gno.land/p/demo/mux"
	"gno.land/p/gnome/alerts"
	"gno.land/p/gnome/blog"
	gnome "gno.land/p/gnome/dao"
)

const (
	dateFormat      = "2006-01-02 15:04 MST"
	shortDateFormat = "Jan 2, 2006"
)

func renderBlog(res *mux.ResponseWriter, _ *mux.Request) {
	// Write header
	res.Write("# " + tutorialsBlog.Title + "\n")
	if tutorialsBlog.Description != "" {
		res.Write(tutorialsBlog.Description + "\n\n")
	}

	// Write tutorials menu
	res.Write(renderMenu() + "\n\n---\n")

	// Write list of published tutorials
	now := time.Now()
	tutorials.Iterate("", "", func(p *blog.Post) bool { // TODO: Add post pagination support
		// Skip posts that should be published at a future date
		if p.PublishAt.IsZero() || p.PublishAt.After(now) {
			return false
		}

		// Skip posts that are not published or being revised
		if p.Status != blog.StatusPublished && p.Status != blog.StatusRevised {
			return false
		}

		url := newRealmURL("posts/" + p.Slug)
		date := p.PublishAt.UTC().Format(shortDateFormat)
		res.Write("**[" + p.Title + "](" + url + ")**</br>")
		res.Write("_Published: " + date + "_\n\n")
		return false
	})
}

func renderPost(res *mux.ResponseWriter, req *mux.Request) {
	slug := req.GetVar("slug")
	p, found := tutorialsBlog.GetPost(slug)
	if !found {
		res.Write("Post not found")
		return
	}

	if p.Status == blog.StatusRevised {
		res.Write(alerts.NewWarning("Tutorial content is being revised"))
	}

	// TODO: Add post tags with links
	res.Write("# " + p.Title + "\n")
	res.Write("- Author(s): " + p.Authors.String() + "\n")

	if len(p.Editors) > 0 {
		res.Write("- Editors(s): " + p.Editors.String() + "\n")
	}

	res.Write("- Publisher(s): " + p.Publishers.String() + "\n")
	res.Write("- Status: " + p.Status.String() + "\n")
	res.Write("- Content Hash: " + p.ContentHash + "\n")
	res.Write("- Created: " + p.CreatedAt.UTC().Format(dateFormat) + "\n")
	if !p.UpdatedAt.IsZero() {
		res.Write("- Updated: " + p.UpdatedAt.UTC().Format(dateFormat) + "\n")
	}

	if len(p.Tags) > 0 {
		res.Write("- Tag(s): " + renderTagLinks(p.Tags) + "\n")
	}

	if p.Content != "" {
		res.Write("\n" + p.Content)
	}
}

func renderDrafts(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# " + tutorialsBlog.Title + ": Drafts\n")
	tutorials.Iterate("", "", func(p *blog.Post) bool { // TODO: Add pagination support
		if p.Status != blog.StatusDraft {
			return false
		}

		url := newRealmURL("posts/" + p.Slug)
		date := p.CreatedAt.UTC().Format(shortDateFormat)
		res.Write("**[" + p.Title + "](" + url + ")**</br>")
		res.Write("_Created: " + date + "_\n\n")
		return false
	})
}

func renderRevisions(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# " + tutorialsBlog.Title + ": Revisions\n")
	tutorials.Iterate("", "", func(p *blog.Post) bool { // TODO: Add pagination support
		if p.Status != blog.StatusRevised {
			return false
		}

		url := newRealmURL("posts/" + p.Slug)
		date := p.PublishAt.UTC().Format(shortDateFormat)
		res.Write("**[" + p.Title + "](" + url + ")**</br>")
		res.Write("_Published: " + date + "_\n\n")
		return false
	})
}

func renderTags(res *mux.ResponseWriter, req *mux.Request) {
	res.Write("# " + tutorialsBlog.Title + ": Tags\n")
	tags.IterateTags(func(tag string) bool {
		res.Write("- [" + tag + "](" + newRealmURL("tags/"+tag) + ")\n")
		return false
	})
}

func renderPostsByTag(res *mux.ResponseWriter, req *mux.Request) {
	tag := req.GetVar("name")
	res.Write("# " + tutorialsBlog.Title + ": Tag `" + tag + "`\n")

	if tag == "" {
		return
	}

	tags.IteratePosts(tag, func(p *blog.Post) bool {
		if p.Status != blog.StatusPublished && p.Status != blog.StatusRevised {
			return false
		}

		url := newRealmURL("posts/" + p.Slug)
		date := p.PublishAt.UTC().Format(shortDateFormat)
		res.Write("**[" + p.Title + "](" + url + ")**</br>")
		res.Write("_Published: " + date + "_\n\n")
		return false
	})
}

func renderParams(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# " + tutorialsBlog.Title + ": Parameters\n")
	res.Write("## Proposal\n")
	res.Write("**Voting Periods**\n")
	parameters.VotingPeriods.Iterate(func(name string, period time.Duration) bool {
		res.Write("- `" + name + "`: " + gnome.HumanizeDuration(period) + "\n")
		return false
	})
}

func renderAlerts() string {
	if locked {
		msg := "Realm is locked"
		if nextVersionRealmPath != "" {
			link := alerts.NewLink("https://"+nextVersionRealmPath, nextVersionRealmPath)
			msg += "</br>This realm is deprecated in favor of a new version found at " + link
		}

		return alerts.NewError(msg)
	}
	return ""
}

func renderMenu() string {
	items := []string{
		"**[drafts](" + newRealmURL("drafts") + ")**",
		"**[revisions](" + newRealmURL("revisions") + ")**",
	}

	// Add taxonomy entries
	tags.IterateTags(func(tag string) bool {
		items = append(items, "**["+tag+"]("+newRealmURL("tags/"+tag)+")**")
		return false
	})

	return strings.Join(items, " ")
}

func renderTagLinks(tags []string) string {
	var links []string
	for _, t := range tags {
		links = append(links, "["+t+"]("+newRealmURL("tags/"+t)+")")
	}
	return strings.Join(links, ", ")
}

func newRealmURL(renderPath string) string {
	// TODO: Get the prefix for the current realm package path
	return "/r/gnome/tutorials/pre2:" + renderPath
}
