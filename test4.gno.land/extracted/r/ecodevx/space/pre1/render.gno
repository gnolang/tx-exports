package space

import (
	"std"
	"strconv"
	"strings"
	"time"

	"gno.land/p/demo/mux"
	"gno.land/p/demo/ufmt"

	"gno.land/p/ecodevx/alerts"
	gnome "gno.land/p/ecodevx/dao"
)

// TODO: Should it be a parameter?
const homeDescription = `Welcome to Gno.me,
an educational and community platform for gnomes and newcomers to learn,
share and build together. Gno.me exists to encourage, challenge, and develop
the skills and standards of people interested in building a smart contract
ecosystem of innovative, responsible and curious gnomes.
`

const maxDataSectionItems = 4

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	renderHeader(res)
	res.Write("\n" + homeDescription + "\n")
	renderHomeDataSections(res)
	renderHomeNews(res)
	renderHomeTools(res)
	renderHomeFooter(res)
}

func renderNews(res *mux.ResponseWriter, req *mux.Request) {
	renderHomeMenu(res)

	res.Write("## News\n")

	// TODO: Add pagination support
	indexes.News.ReverseIterate(func(n *News) bool {
		res.Write(n.String() + "\n")
		return false
	})
}

func renderNewsByTag(res *mux.ResponseWriter, req *mux.Request) {
	renderHomeMenu(res)

	tag := req.GetVar("tag")
	res.Write("## News: " + tag + "\n")

	// TODO: Add pagination support
	for _, n := range indexes.News.GetByTag(tag) {
		res.Write(n.String() + "\n")
	}
}

func renderDataSection(res *mux.ResponseWriter, req *mux.Request) {
	section, found := indexes.DataSection.GetBySlug(req.GetVar("slug"))
	if !found || section.Disabled {
		res.Write("section not found")
		return
	}

	renderHomeMenu(res)

	res.Write("## gno.me: " + section.Title + "\n")

	// TODO: Add pagination support
	section.Datasource.Iterate("", func(_ string, r Record) bool {
		assertPrevRealmPath(section.Realm)
		renderDatasourceRecord(res, section, r)
		return false
	})
}

func renderDataSectionByTag(res *mux.ResponseWriter, req *mux.Request) {
	section, found := indexes.DataSection.GetBySlug(req.GetVar("slug"))
	if !found || section.Disabled {
		res.Write("section not found")
		return
	}

	renderHomeMenu(res)

	tag := req.GetVar("tag")
	res.Write(ufmt.Sprintf("## gno.me: %s (%s)\n", section.Title, tag))

	// TODO: Add pagination support
	section.Datasource.IterateByTag(tag, "", func(_ string, r Record) bool {
		assertPrevRealmPath(section.Realm)
		renderDatasourceRecord(res, section, r)
		return false
	})
}

func renderContent(res *mux.ResponseWriter, req *mux.Request) {
	section, found := indexes.DataSection.GetBySlug(req.GetVar("sectionSlug"))
	if !found || section.Disabled {
		res.Write("section not found")
		return
	}

	var output string
	err := section.Datasource.GetContent(req.GetVar("contentSlug"), func(content string) {
		assertPrevRealmPath(section.Realm)
		output = content
	})
	if err != nil {
		panic(err)
	}

	// TODO: Add a title for the section
	renderHomeMenu(res)
	res.Write(output)
}

func renderDatasources(res *mux.ResponseWriter, _ *mux.Request) {
	renderHomeMenu(res)

	res.Write("# Data Sections\n")
	indexes.DataSection.Iterate(func(s *DataSection) bool {
		height := strconv.FormatInt(s.BlockHeight, 10)

		res.Write("## " + s.Title + "\n")
		res.Write("- Slug: [" + s.Slug + "](https://gno.land" + newSectionPath(s.Slug) + ")\n")
		res.Write("- Realm: [" + s.Realm + "](https://" + s.Realm + ")\n")
		res.Write("- Block Height: [" + height + "](" + newBlockURL(s.BlockHeight) + ")\n")

		if s.Disabled {
			res.Write("- Disabled: Yes\n\n")
		} else {
			res.Write("- Disabled: No\n\n")
		}

		return false
	})
}

func renderParams(res *mux.ResponseWriter, _ *mux.Request) {
	res.Write("# Gnome Space: Parameters\n")
	res.Write("## Proposal\n")
	res.Write("**General**\n")
	res.Write("- Space DAO Path: " + parameters.SpaceDAO + "\n")
	res.Write("\n**Voting Periods**\n")
	parameters.VotingPeriods.Iterate(func(name string, period time.Duration) bool {
		res.Write("- `" + name + "`: " + gnome.HumanizeDuration(period) + "\n")
		return false
	})
}

func renderHeader(res *mux.ResponseWriter) {
	res.Write("# gno.me\n")
	renderHomeMenu(res)
}

func renderHomeMenu(res *mux.ResponseWriter) {
	items, found := indexes.Link.Get(SectionPlatform)
	if !found {
		return
	}

	var menu []string
	for _, link := range items {
		menu = append(menu, ufmt.Sprintf("/[%s](%s)", strings.ToLower(link.Title), newRealmURL(link.URL)))
	}
	res.Write(strings.Join(menu, "&nbsp;&nbsp;") + "\n\n---\n\n")
}

func renderHomeDataSections(res *mux.ResponseWriter) {
	indexes.DataSection.Iterate(func(s *DataSection) bool {
		if s.Disabled {
			return false
		}

		var (
			i   int
			url = newSectionPath(s.Slug)
		)

		res.Write("## " + gnome.EscapeHTML(s.Title) + "\n")
		res.Write(ufmt.Sprintf("_([view all](%s))_\n\n", url))

		s.Datasource.Iterate("", func(_ string, r Record) bool {
			// Make sure that records come from the data section realm
			caller := std.PrevRealm().PkgPath()
			if caller != s.Realm {
				res.Write(
					"> &nbsp;**Error:**  \n" +
						" &nbsp; &nbsp;Expected section content from _" + s.Realm + "_.  \n" +
						" &nbsp; &nbsp;Content from _" + caller + "_ is not allowed.\n",
				)
				return true
			}

			// Don't render all records in the home, render a reduced number
			i++
			renderDatasourceRecord(res, s, r)
			return (i == maxDataSectionItems)
		})

		return false
	})
}

func renderHomeNews(res *mux.ResponseWriter) {
	if indexes.News.Size() == 0 {
		return
	}

	res.Write("## News\n")
	res.Write(ufmt.Sprintf("_([view all](%s))_\n\n", newRealmURL("news")))

	indexes.News.ReverseIterate(func(n *News) bool {
		res.Write(n.String() + "\n")
		return false
	})
}

func renderHomeTools(res *mux.ResponseWriter) {
	if len(tools) == 0 {
		return
	}

	res.Write("## Tools\n")
	res.Write("These resources are designed to enhance your Gno experience and streamline your workflow.\n\n")

	for _, tool := range tools {
		res.Write(tool.String() + "\n")
	}
}

func renderHomeFooter(res *mux.ResponseWriter) {
	res.Write("---\n")
	renderHomeFooterLinks(res)

	footer := []string{
		"©2024 gno.me",
		ufmt.Sprintf("[Terms and Conditions](%s)", newRealmURL("terms-and-conditions")),
		ufmt.Sprintf("[Privacy Policy](%s)", newRealmURL("privacy-policy")),
	}
	res.Write("---\n" + strings.Join(footer, strings.Repeat("&nbsp;", 4)))
}

func renderHomeFooterLinks(res *mux.ResponseWriter) {
	sections := []Section{SectionPlatform, SectionResources, SectionSocials}
	for _, s := range sections {
		items, found := indexes.Link.Get(s)
		if !found {
			continue
		}

		res.Write("**" + strings.Title(string(s)) + "**\n")
		for _, link := range items {
			res.Write(ufmt.Sprintf("- %s\n", link))
		}
		res.Write("\n")
	}
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

func renderDatasourceRecord(res *mux.ResponseWriter, s *DataSection, r Record) {
	// TODO: Validate required record values before rendering
	sectionURL := newSectionPath(s.Slug)
	contentURL := newContentPath(s.Slug, r.GetSlug())
	if link := r.GetImage(); link != "" {
		res.Write(ufmt.Sprintf("[![](%s)](%s)\n", link, contentURL))
	}

	res.Write(ufmt.Sprintf("**[%s](%s)**\n\n", r.GetTitle(), contentURL))
	res.Write(ufmt.Sprintf("%s\n\n", r.GetDescription()))
	res.Write(r.GetCreationTime().UTC().Format("Jan 02, 2006 (MST)"))

	var tags []string
	for _, tag := range r.GetTags() {
		tags = append(tags, ufmt.Sprintf("[%s](%s)", tag, sectionURL+"/"+tag))
	}

	if len(tags) > 0 {
		res.Write(" - " + strings.Join(tags, ", "))
	}
	res.Write("\n\n")
}

func newSectionPath(slug string) string {
	return newRealmURL("section/" + slug)
}

func newContentPath(sectionSlug, contentSlug string) string {
	return newRealmURL("content/" + sectionSlug + "/" + contentSlug)
}

func newBlockURL(height int64) string {
	return "https://gnoscan.io/blocks/" + strconv.FormatInt(height, 10)
}

func assertPrevRealmPath(path string) {
	caller := std.PrevRealm().PkgPath()
	if caller != path {
		panic("expected datasource content from " + path + ", " + caller + " is not allowed")
	}
}
