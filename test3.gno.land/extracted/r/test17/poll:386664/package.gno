package poll

import (
	"std"
	"strconv"
	"strings"
	"time"

	"gno.land/p/demo/ufmt"
)

const (
	ChoiceNone             Choice = 0x0
	ChoiceSinceInception   Choice = 0x1
	ChoiceOneOrTwoYearsAgo Choice = 0x2
	ChoiceThisYear         Choice = 0x4
	ChoiceThisMonth        Choice = 0x8
)

const (
	dateFmt = "2006-01-02 15:04 MST"
)

var (
	poll = Poll{
		Question: "When did you first hear about Gno.land?",
		Answers: []Answer{
			{Choice: ChoiceThisMonth},
			{Choice: ChoiceThisYear},
			{Choice: ChoiceOneOrTwoYearsAgo},
			{Choice: ChoiceSinceInception},
		},
	}
	admin         = std.Address("g1fsu3z335h5qngf7t3lmakvpmpwg9ae76tqwh7c")
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
		Participants []Participant
	}
)

type Participant struct {
	Address std.Address
	Date    time.Time
}

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
		for _, p := range answer.Participants {
			if p.Address == addr {
				return true
			}
		}
	}
	return false
}

// 👋 Welcome to the GnoYourDate (Know-Your-Gno-Date) Poll! 🎈🎈🎈
//
// You are now viewing the Vote function.
// This function allows you to submit your choice for the poll.
//
// ❔ Question: When did you first hear about Gno.land?
// 👇 Options:
//  - This month
//  - This year
//  - 1-2 years ago
//  - Since its inception
//
// 📍 Please make sure to mark the option you choose as 'True (Yes)' and mark all other options as 'False (No)' for your vote to be valid.
// 📍 If you select multiple options as 'True (Yes)', your vote will be considered invalid.
//
// 📢 Now, please cast your vote using the form below, then click the "Call" button to submit it.
func Vote(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception bool) string {
	if isRealmLocked {
		if nextRealmPath == "" {
			panic("Realm is locked")
		}

		// Allow TX to succeed but return an "error" message with the link to vote on the next realm version.
		// Panic and error results are not used to favor GnoStudio Connect usability to making links clickable.
		return "This realm is deprecated, the new version can be found at " + nextRealmPath 
	}

	choice := mustCreateChoiceFromVoteArgs(thisMonth, thisYear, oneOrTwoYearsAgo, sinceInception)
	participant := Participant{
		Address: std.GetOrigCaller(),
		Date: time.Now(),
	}
	assertFirstVote(participant.Address)

	for i, a := range poll.Answers {
		if a.Choice == choice {
			poll.Answers[i].Participants = append(poll.Answers[i].Participants, participant)
			break
		}
	}

	return ufmt.Sprintf(
		`You have successfully voted Yes on '%s'. You can check out the results at https://%s.%s`,
		getAnswerLabel(choice),
		std.GetChainID(),
		std.CurrentRealmPath(),
	)
}

// Render returns a Markdown string with the poll details.
func Render(_ string) string {
	var buf strings.Builder

	if isRealmLocked {
		var msg string
		if nextRealmPath == "" {
			msg = "Realm is locked."
		} else {
			msg += ufmt.Sprintf(
				"Realm is deprecated. </br>The new version can be found at <a href=\"%s\">%s</a>",
				nextRealmPath,
				nextRealmPath,
			)
		}

		buf.WriteString(
			`<p style="padding: .75rem 1.25rem; border: 1px solid #FFEEBA; background-color: #FFF3CD; color: #856404; border-radius: .25rem">` +
				msg +
				"</p>\n\n",
		)
	}

	buf.WriteString("# GnoYourDate Poll\n👋 Welcome to the GnoYourDate (Know-Your-Gno-Date) Poll! 🎈🎈🎈\n\n")
	buf.WriteString(ufmt.Sprintf("## Question: %s\n", poll.Question))

	if !isRealmLocked {
		url := getGnoStudioConnectVoteURL(std.CurrentRealmPath())
		buf.WriteString("👉 You can participate in the poll by [submitting your vote from here](" + url + ") 👈\n")
	}

	buf.WriteString("### Choices:\n")
	for _, c := range [4]Choice{ChoiceThisMonth, ChoiceThisYear, ChoiceOneOrTwoYearsAgo, ChoiceSinceInception} {
		buf.WriteString(
			ufmt.Sprintf("- %s: **%d** vote(s)\n", getAnswerLabel(c), poll.GetCount(c)),
		)
	}

	buf.WriteString(
		ufmt.Sprintf("\nThe total number of answers is **%d**\n", poll.GetTotalCount()),
	)

	// Render participant addresses when there are votes
	if poll.GetTotalCount() > 0 {
		buf.WriteString("### Participants:\nList of participants grouped by their vote\n")
		for _, a := range poll.Answers {
			// Skip anwers without votes
			if len(a.Participants) == 0 {
				continue
			}

			buf.WriteString("\n- **" + getAnswerLabel(a.Choice) + "**:\n")
			for _, p := range a.Participants {
				date := p.Date.UTC().Format(dateFmt)
				buf.WriteString("  - " + p.Address.String() + " <small><i>(voted at " + date + ")</i></small>\n")
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

	isRealmLocked = true
	nextRealmPath = realmPath
	return "The poll has been moved to " + realmPath
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
			"You haven't selected an option. Please submit your vote by selecting one of the options as 'True (Yes)'.",
		)
	default:
		panic(
			"Multiple options have been selected. Please submit your vote by selecting only one of the options as 'True (Yes)'.\n" +
				"The option you choose must be marked as 'True (Yes)', while all other options are marked as 'False (No)'.",
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