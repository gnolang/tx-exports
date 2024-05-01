package v3

import (
	"std"
	"strings"
	"time"

	"gno.land/p/demo/ufmt"
)

const maxCharsCount = 256

type Feedback struct {
	ID        int
	User      std.Address
	Content   string
	Response  string
	CreatedAt time.Time
	RespondAt time.Time
}

var (
	nextID    = 0
	isLocked  = false
	feedbacks = []Feedback{}
	modAddrs  = []std.Address{
		// TODO: put moderator addresses
		"g1fdk37llu9sfu9mdupmzjx34v2nrrdnk2757e0j",
	}
	ownerAddr = std.Address(
		// TODO: put realm's owner address
		"g1fdk37llu9sfu9mdupmzjx34v2nrrdnk2757e0j",
	)
)

func findFeedback(id int) (int, bool) {
	// TODO: use avl and seqid when will move to test4
	for i := range feedbacks {
		if feedbacks[id].ID == id {
			return i, true
		}
	}

	return 0, false
}

func isModerator(addr std.Address) bool {
	for _, modAddr := range modAddrs {
		if modAddr == addr {
			return true
		}
	}

	return false
}

// assertIsModerator checks whether a current caller is owner or a moderator.
func assertIsModerator() {
	actorId := std.GetOrigCaller()
	isAllowed := actorId == ownerAddr || isModerator(actorId)
	if !isAllowed {
		panic("Access Denied")
	}
}

// assertIsOwner checks whether a current caller is a realm owner.
func assertIsOwner() {
	actorId := std.GetOrigCaller()
	isAllowed := actorId == ownerAddr
	if !isAllowed {
		panic("Access Denied")
	}
}

// assertNotLocked interrupts execution if realm is locked.
func assertNotLocked() {
	if isLocked {
		panic("Realm is locked")
	}
}

// LockFeedback locks the realm, preventing further feedback submissions.
func LockFeedback() string {
	assertIsOwner()
	isLocked = true
	return "Locked"
}

// UnlockFeedback unlocks the realm, allowing further feedback submissions.
func UnlockFeedback() string {
	assertIsOwner()
	isLocked = false
	return "Unlocked"
}

// SubmitFeedback allows users to submit their feedback about GnoStudio.
func SubmitFeedback(message string) string {
	assertNotLocked()

	message = strings.TrimSpace(message)
	if message == "" {
		panic("Message can't be empty")
	}

	if len(message) > maxCharsCount {
		panic("Message is too long")
	}

	id := nextID
	feedbacks = append(feedbacks, Feedback{
		ID:        id,
		User:      std.GetOrigCaller(),
		Content:   message,
		CreatedAt: time.Now(),
	})

	nextID++
	return ufmt.Sprintf("Feedback submitted successfully with ID: %d", id)
}

// BanFeedback used by moderation team to remove feedbacks which violate code of conduct.
func BanFeedback(feedbackID int) string {
	assertNotLocked()
	assertIsModerator()

	i, ok := findFeedback(feedbackID)
	if !ok {
		panic("Feedback not found")
	}

	// Still keep the record but remove a harmful message.
	feedbacks[i].Content = ""
	return "Feedback was removed by a moderator"
}

// RespondToFeedback allows any moderator or realm owner to leave a response to a feedback.
func RespondToFeedback(feedbackID int, response string) string {
	assertNotLocked()
	assertIsModerator()

	i, ok := findFeedback(feedbackID)
	if !ok {
		panic("Feedback not found")
	}

	feedback := feedbacks[i]
	if feedback.Response != "" {
		panic("Feedback already has a response")
	}

	response = strings.TrimSpace(response)
	if response == "" {
		panic("Response can't be empty")
	}

	if len(response) > maxCharsCount {
		panic("Response is too long")
	}

	feedback.RespondAt = time.Now()
	feedback.Response = response
	feedbacks[i] = feedback

	return "Response recorded successfully"
}

// Render displays all feedback and responses.
func Render(_ string) string {
	sb := strings.Builder{}
	sb.WriteString("# Feedback Collection\n")
	for _, fb := range feedbacks {
		sb.WriteString(ufmt.Sprintf("## Feedback #%d\n", fb.ID))
		sb.WriteString(ufmt.Sprintf("From `%s` at %s\n\n", fb.User, fb.CreatedAt.Format(time.RFC1123)))
		if fb.Content == "" {
			sb.WriteString("*Feedback was removed by a moderator*")
		} else {
			sb.WriteString(fb.Content)
		}
		sb.WriteString("\n")

		if fb.Response == "" {
			continue
		}

		sb.WriteString("### Response")
		sb.WriteString(ufmt.Sprintf("At %s\n\n", fb.RespondAt.Format(time.RFC1123)))
		sb.WriteString(fb.Response)
		sb.WriteString("\n\n")
	}
	return sb.String()
}
