package tutorials

import (
	"errors"
	"strings"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/ecodevx/blog"
	gnome "gno.land/p/ecodevx/dao"
)

type creationStrategy struct {
	slug, title, contentHash, contentURL string
	authors, editors                     blog.AddressList
	tags                                 []string
}

func (creationStrategy) Name() string {
	return StrategyNameCreation
}

func (creationStrategy) Quorum() float64 {
	return 0.51
}

func (creationStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameCreation)
	return period
}

func (creationStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (s creationStrategy) Validate(*gnome.Proposal) error {
	if tutorialsBlog.HasPost(s.slug) {
		return errors.New("tutorial URL slug already exists")
	}
	return nil
}

func (creationStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s creationStrategy) Execute(*gnome.DAO) error {
	p := &blog.Post{
		Slug:        s.slug,
		Title:       s.title,
		ContentHash: s.contentHash,
		Authors:     s.authors,
		Editors:     s.editors,
		Status:      blog.StatusDraft,
		Tags:        s.tags,
		CreatedAt:   time.Now(),
	}
	tutorialsBlog.AddPost(p)

	// Update realm indexes
	tutorials.Index(p)
	if len(p.Tags) > 0 {
		tags.Index(p)
	}

	return nil
}

func (s creationStrategy) RenderParams() string {
	var (
		b       strings.Builder
		authors = strings.ReplaceAll(s.authors.String(), ", ", "</br>")
	)

	// TODO: Implement using gno.land/p/demo/ui
	b.WriteString("|||\n|---|---|\n")
	b.WriteString("| Slug: | " + s.slug + " |\n")
	b.WriteString("| Title: | " + gnome.EscapeHTML(s.title) + " |\n")
	b.WriteString("| Content URL: | " + gnome.NewLinkURI(s.contentURL) + " |\n")
	b.WriteString("| Content Hash: | " + s.contentHash + " |\n")

	if len(s.tags) > 0 {
		b.WriteString("| Tag(s): | " + renderTagLinks(s.tags) + " |\n")
	}

	b.WriteString("| Author(s): | </br>" + authors + "</br></br> |\n")

	if len(s.editors) > 0 {
		editors := strings.ReplaceAll(s.editors.String(), ", ", "</br>")
		b.WriteString("| Editor(s): | </br>" + editors + "</br></br> |\n")
	}

	return b.String()
}

type modificationStrategy struct {
	slug, title, currentContentHash, contentHash, contentURL string
	authors, editors                                         blog.AddressList
	tags                                                     []string
}

func (modificationStrategy) Name() string {
	return StrategyNameModification
}

func (modificationStrategy) Quorum() float64 {
	return 0.51
}

func (modificationStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameModification)
	return period
}

func (modificationStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (s modificationStrategy) Validate(*gnome.Proposal) error {
	p, found := tutorialsBlog.GetPost(s.slug)
	if !found {
		return errors.New("tutorial doesn't exists")
	}

	if s.currentContentHash != "" && s.currentContentHash != p.ContentHash {
		return errors.New("tutorial's content has been previously modified")
	}

	for _, addr := range s.authors {
		if p.Authors.HasAddress(addr) {
			return errors.New("author already exists: " + addr.String())
		}
	}

	for _, addr := range s.editors {
		if p.Authors.HasAddress(addr) {
			return errors.New("editor already exists: " + addr.String())
		}
	}

	if len(s.tags) > 0 {
		var seenTags avl.Tree
		for _, t := range s.tags {
			if seenTags.Has(t) {
				return errors.New("duplicated tag: " + t)
			}

			seenTags.Set(t, struct{}{})
		}
	}

	return nil
}

func (modificationStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s modificationStrategy) Execute(*gnome.DAO) error {
	p, _ := tutorialsBlog.GetPost(s.slug)

	if s.title != "" {
		p.Title = s.title
	}

	if len(s.authors) > 0 {
		p.Authors = append(p.Authors, s.authors...)
	}

	if len(s.editors) > 0 {
		p.Editors = append(p.Editors, s.editors...)
	}

	// Update tag index
	if len(s.tags) > 0 {
		tags.Remove(p)
		p.Tags = s.tags
		tags.Index(p)
	}

	// Changing content hash converts post to a revised until new content is setted
	if s.contentHash != "" {
		p.Status = blog.StatusRevised
		p.ContentHash = s.contentHash
	}

	p.UpdatedAt = time.Now()
	return nil
}

func (s modificationStrategy) RenderParams() string {
	var b strings.Builder

	// TODO: Implement using gno.land/p/demo/ui
	b.WriteString("|||\n|---|---|\n")
	b.WriteString("| Slug: | [" + s.slug + "](" + newRealmURL("posts/"+s.slug) + ") |\n")

	if s.title != "" {
		b.WriteString("| Title: | " + gnome.EscapeHTML(s.title) + " |\n")
	}

	if s.contentHash != "" {
		b.WriteString("| Content URL: | " + gnome.NewLinkURI(s.contentURL) + " |\n")
		b.WriteString("| Content Hash: | " + s.contentHash + " |\n")
		b.WriteString("| Modifies Content Hash: | " + s.currentContentHash + " |\n")
	}

	if len(s.tags) > 0 {
		b.WriteString("| Tag(s): | " + renderTagLinks(s.tags) + " |\n")
	}

	if len(s.authors) > 0 {
		authors := strings.ReplaceAll(s.authors.String(), ", ", "</br>")
		b.WriteString("| Author(s): | </br>" + authors + "</br></br> |\n")
	}

	if len(s.editors) > 0 {
		editors := strings.ReplaceAll(s.editors.String(), ", ", "</br>")
		b.WriteString("| Editor(s): | </br>" + editors + "</br></br> |\n")
	}

	return b.String()
}

type deletionStrategy struct {
	slug string
}

func (deletionStrategy) Name() string {
	return StrategyNameDeletion
}

func (deletionStrategy) Quorum() float64 {
	return 0.51
}

func (deletionStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameDeletion)
	return period
}

func (deletionStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (deletionStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s deletionStrategy) Validate(*gnome.Proposal) error {
	if !tutorialsBlog.HasPost(s.slug) {
		return errors.New("tutorial doesn't exists")
	}
	return nil
}

func (s deletionStrategy) Execute(*gnome.DAO) error {
	p, found := tutorialsBlog.RemovePost(s.slug)
	if !found {
		return errors.New("tutorial not found")
	}

	// Update realm indexes
	tutorials.Remove(p)
	if len(p.Tags) > 0 {
		tags.Remove(p)
	}

	return nil
}

func (s deletionStrategy) RenderParams() string {
	return "Slug: [" + s.slug + "](" + newRealmURL("posts/"+s.slug) + ")"
}
