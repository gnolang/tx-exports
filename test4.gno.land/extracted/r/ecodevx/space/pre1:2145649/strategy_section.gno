package space

import (
	"errors"
	"strconv"
	"strings"
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

type dataSectionStrategy struct {
	slug, title, realm string
	blockHeight        int64
	datasource         Datasource
}

func (dataSectionStrategy) Name() string {
	return StrategyNameDataSection
}

func (dataSectionStrategy) Quorum() float64 {
	return 0.51
}

func (dataSectionStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameDataSection)
	return period
}

func (dataSectionStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (dataSectionStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s dataSectionStrategy) Validate(*gnome.Proposal) error {
	if _, exists := indexes.DataSection.GetBySlug(s.slug); exists {
		return errors.New("data section slug is already taken: " + s.slug)
	}
	return nil
}

func (s dataSectionStrategy) Execute(*gnome.DAO) error {
	indexes.DataSection.Index(&DataSection{
		Slug:        s.slug,
		Title:       s.title,
		Realm:       s.realm,
		BlockHeight: s.blockHeight,
		Datasource:  s.datasource,
	})
	return nil
}

func (s dataSectionStrategy) RenderParams() string {
	var (
		b      strings.Builder
		height = strconv.FormatInt(s.blockHeight, 10)
	)

	b.WriteString("|||\n|---|---|\n")
	b.WriteString("| Slug: | " + s.slug + " |\n")
	b.WriteString("| Title: | " + gnome.EscapeHTML(s.title) + " |\n")
	b.WriteString("| Realm: | " + s.realm + " |\n")
	b.WriteString("| Block Height: | [" + height + "](" + newBlockURL(s.blockHeight) + ") |\n")

	return b.String()
}
