package poll_v1

import (
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/ufmt"
)

const (
	ChoiceNone             Choice = 0x0
	ChoiceSinceInception   Choice = 0x1
	ChoiceOneOrTwoYearsAgo Choice = 0x2
	ChoiceThisYear         Choice = 0x4
	ChoiceThisMonth        Choice = 0x8
)

var (
	poll = Poll{
		Question: "When did you first learn about Gno.land?",
		Answers: []Answer{
			{Choice: ChoiceThisMonth},
			{Choice: ChoiceThisYear},
			{Choice: ChoiceOneOrTwoYearsAgo},
			{Choice: ChoiceSinceInception},
		},
	}
	admin         = std.Address("g1uf8u5jf2m9l80g0zsfq7tufl3qufqc4393jtkl")
	isRealmLocked bool
	nextRealmPath string
)

type (
	// Choice defines a type for poll choices.
	Choice byte

	// Poll tracks the number of votes for a set of pre defined answers.
	Poll struct {
		Question string
		Answers  []Answer
	}

	// Answer contains the number of votes for a poll choice.
	Answer struct {
		Choice       Choice
		Participants []std.Address
	}
)

// String returns the choice as a string.
func (c Choice) String() string {
	return strconv.Itoa(int(c))
}

// GetCount returns the number of votes submitted for a poll choice.
func (p Poll) GetCount(c Choice) int {
	for _, a := range p.Answers {
		if a.Choice == c {
			return len(a.Participants)
		}
	}
	return 0
}

// GetTotalCount returns the total number of votes.
func (p Poll) GetTotalCount() int {
	var count int
	for _, a := range p.Answers {
		count += len(a.Participants)
	}
	return count
}

// HasVoted checks if an address already submitted a vote.
func (p Poll) HasVoted(addr std.Address) bool {
	for _, answer := range p.Answers {
		for _, a := range answer.Participants {
			if a == addr {
				return true
			}
		}
	}
	return false
}

// Vote submits a vote for one of the poll choices.
//
// Only one of the choices should be selected to consider the vote valid.
// The answer you choose should be marked as True (Yes), ensuring that all other options are marked as False (No).
//
// When did you first learn about Gno.land?
// - This month
// - This year
// - 1-2 years ago
// - Since its inception
func Vote(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception bool) string {
	if isRealmLocked {
		if nextRealmPath == "" {
			panic("Realm is locked")
		}

		// Allow TX to succeed but return an "error" message with the link to vote on the next realm version.
		// Panic and error results are not used to favor GnoStudio Connect usability to making links clickable.
		url := getGnoStudioConnectVoteURL("gno.land" + nextRealmPath)
		return "This realm is deprecated but you can submit a vote to the updated version at " + url
	}

	choice := mustCreateChoiceFromVoteArgs(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception)
	caller := std.GetOrigCaller()
	assertFirstVote(caller)

	for i, a := range poll.Answers {
		if a.Choice == choice {
			poll.Answers[i].Participants = append(poll.Answers[i].Participants, caller)
			break
		}
	}

	return ufmt.Sprintf(
		`You have successfully voted yes on "%s" you can check out the result at https://%s.%s`,
		getAnswerLabel(choice),
		std.GetChainID(),
		std.CurrentRealmPath(),
	)
}

// Render returns a Markdown string with the poll details.
func Render(string) string {
	var buf strings.Builder

	if isRealmLocked {
		var msg string
		if nextRealmPath == "" {
			msg = "Realm is locked"
		} else {
			msg += ufmt.Sprintf(
				"Realm is deprecated</br>An updated version can be found at <a href=\"%s\">https://%s.gno.land%s</a>",
				nextRealmPath,
				std.GetChainID(),
				nextRealmPath,
			)
		}

		buf.WriteString(
			`<p style="padding: .75rem 1.25rem; border: 1px solid #FFEEBA; background-color: #FFF3CD; color: #856404; border-radius: .25rem">` +
				msg +
				"</p>\n\n",
		)
	}

	buf.WriteString(ufmt.Sprintf("## Poll: %s\n", poll.Question))

	if !isRealmLocked {
		url := getGnoStudioConnectVoteURL(std.CurrentRealmPath())
		buf.WriteString("👉 You can participate in the poll by [submitting your vote](" + url + ") 👈\n")
	}

	buf.WriteString("### Answers:\n")
	for _, c := range [4]Choice{ChoiceThisMonth, ChoiceThisYear, ChoiceOneOrTwoYearsAgo, ChoiceSinceInception} {
		buf.WriteString(
			ufmt.Sprintf("- %s: %d vote(s)\n", getAnswerLabel(c), poll.GetCount(c)),
		)
	}

	buf.WriteString(
		ufmt.Sprintf("\nThe total number of answers is **%d**\n", poll.GetTotalCount()),
	)

	// Render participant addresses when there are votes
	if poll.GetTotalCount() > 0 {
		buf.WriteString("### Participants:\nList of participants grouped by their voted answer\n")
		for _, a := range poll.Answers {
			// Skip anwers without votes
			if len(a.Participants) == 0 {
				continue
			}

			buf.WriteString("\n- **" + getAnswerLabel(a.Choice) + "**:\n")
			for _, addr := range a.Participants {
				buf.WriteString("  - " + addr.String() + "\n")
			}
		}
	}

	return buf.String()
}

// GetAdmin returns the address of the Realm admin account.
func GetAdmin() string {
	return admin.String()
}

// DeprecateRealm deprecates the realm in favor of another realm.
// Depecation locks this realm to disallow new votes.
func DeprecateRealm(realmPath string) string {
	assertCallerIsAdmin()

	realmPath = strings.TrimSpace(realmPath)
	if realmPath == "" {
		panic("Realm path is empty")
	}

	if !strings.HasPrefix(realmPath, "/r/") {
		panic("Realm path must start with /r/")
	}

	if realmPath == strings.TrimPrefix(std.CurrentRealmPath(), "gno.land") {
		panic("Realm path must be different than current realm's path")
	}

	isRealmLocked = true
	nextRealmPath = realmPath
	return "The poll has been moved to https://" + std.GetChainID() + ".gno.land" + realmPath
}

// LockRealm locks the realm disallowing new vote submission.
func LockRealm() string {
	assertCallerIsAdmin()

	isRealmLocked = true
	return "Realm locked successfully"
}

// UnlockRealm unlocks the realm allowing new votes to be submitted.
func UnlockRealm() string {
	assertCallerIsAdmin()

	isRealmLocked = false
	nextRealmPath = ""
	return "Realm unlocked successfully"
}

func getAnswerLabel(c Choice) string {
	switch c {
	case ChoiceThisMonth:
		return "This month"
	case ChoiceThisYear:
		return "This year"
	case ChoiceOneOrTwoYearsAgo:
		return "1-2 years ago"
	case ChoiceSinceInception:
		return "Since its inception"
	default:
		return "None"
	}
}

func getGnoStudioConnectVoteURL(realmPath string) string {
	return ufmt.Sprintf(
		"https://gno.studio/connect/view/%s?network=%s&tab=functions#Vote",
		realmPath,
		std.GetChainID(),
	)
}

func mustCreateChoiceFromVoteArgs(voteArgs ...bool) Choice {
	var c Choice
	for _, arg := range voteArgs {
		c <<= 1 // shift left
		if arg {
			c |= 1 // last bit on
		}
	}

	switch c {
	case ChoiceThisMonth, ChoiceThisYear, ChoiceOneOrTwoYearsAgo, ChoiceSinceInception:
		return c
	case ChoiceNone:
		panic(
			"No choice has been selected, you should submit a vote for one of the answers.\n" +
				"Only one of the choices should be selected to consider the vote as valid.",
		)
	default:
		panic(
			"Multiple choices has been selected, you should submit a vote for only one answer.\n" +
				"The answer you choose should be selected as True (Yes) making sure that all other options are selected as False (No).",
		)
	}
}

func assertFirstVote(addr std.Address) {
	if poll.HasVoted(addr) {
		panic("This address already voted")
	}
}

func assertCallerIsAdmin() {
	if admin != std.GetOrigCaller() {
		panic("Caller is not admin")
	}
}