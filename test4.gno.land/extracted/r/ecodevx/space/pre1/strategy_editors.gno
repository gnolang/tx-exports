package space

import (
	"errors"
	"std"
	"strings"
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

type editorsModificationStrategy struct {
	newEditors, removeEditors []std.Address
}

func (editorsModificationStrategy) Name() string {
	return StrategyNameEditorsModification
}

func (editorsModificationStrategy) Quorum() float64 {
	return 0.51
}

func (editorsModificationStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameEditorsModification)
	return period
}

func (editorsModificationStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (editorsModificationStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s editorsModificationStrategy) Validate(*gnome.Proposal) error {
	for _, e := range s.newEditors {
		for _, addr := range editors {
			if addr == e {
				return errors.New("address is already an editor: " + e.String())
			}
		}
	}

	for _, e := range s.removeEditors {
		for _, addr := range editors {
			if addr == e {
				continue
			}

			return errors.New("address is not an editor: " + e.String())
		}
	}
	return nil
}

func (s editorsModificationStrategy) Execute(*gnome.DAO) error {
	for _, e := range s.removeEditors {
		for i, addr := range editors {
			if addr != e {
				continue
			}

			editors = append(editors[:i], editors[i+1:]...)
		}
	}

	for _, e := range s.newEditors {
		editors = append(editors, e)
	}
	return nil
}

func (s editorsModificationStrategy) RenderParams() string {
	var b strings.Builder

	b.WriteString("|||\n|---|---|\n")

	if len(s.newEditors) > 0 {
		var editors []string
		for _, m := range s.newEditors {
			editors = append(editors, m.String())
		}

		b.WriteString("| New Editors: | " + strings.Join(editors, "</br>") + "</br></br> |\n")
	}

	if len(s.removeEditors) > 0 {
		var editors []string
		for _, m := range s.removeEditors {
			editors = append(editors, m.String())
		}

		b.WriteString("| Editors to Remove: | " + strings.Join(editors, "</br>") + " |\n")
	}

	return b.String()
}
