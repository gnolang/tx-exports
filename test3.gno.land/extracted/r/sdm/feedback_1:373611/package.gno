package feedback_1

import (
	"std"
	"strings"
	"time"

	"gno.land/p/demo/ufmt"
)


const (
	maxCharsCount = 256
	notFoundIndex = -1

	// ownerAddr is wallet address of realm admin.
	ownerAddr = std.Address("g15ruzptpql4dpuyzej0wkt5rq6r26kw4nxu9fwd")
)

var (
	// HTML escaping.
	htmlQuot = []byte("&#34;") // shorter than "&quot;"
	htmlApos = []byte("&#39;") // shorter than "&apos;" and apos was not in HTML until HTML5
	htmlAmp  = []byte("&amp;")
	htmlLt   = []byte("&lt;")
	htmlGt   = []byte("&gt;")
	htmlNull = []byte("\uFFFD")
)

type Feedback struct {
	ID        int
	User      std.Address
	Content   string
	Response  string
	CreatedAt time.Time
	RespondAt time.Time
}

var (
	nextID    = 1
	isLocked  = false
	feedbacks = []Feedback{}
	modAddrs  = []std.Address{}
)

func stripHtml(input string) string {
	// Copy from Go's `template.HTMLEscape`.
	// See: $GOROOT/src/text/template/funcs.go

	// Avoid allocation if we can.
	if !strings.ContainsAny(input, "'\"&<>\000") {
		return input
	}

	b := []byte(input)
	w := strings.Builder{}
	last := 0
	for i, c := range b {
		var html []byte
		switch c {
		case '\000':
			html = htmlNull
		case '"':
			html = htmlQuot
		case '\'':
			html = htmlApos
		case '&':
			html = htmlAmp
		case '<':
			html = htmlLt
		case '>':
			html = htmlGt
		default:
			continue
		}
		w.Write(b[last:i])
		w.Write(html)
		last = i + 1
	}

	w.Write(b[last:])
	return w.String()
}

func findFeedback(id int) (int, bool) {
	// TODO: use avl and seqid when will move to test4
	for i := range feedbacks {
		if feedbacks[i].ID == id {
			return i, true
		}
	}

	return notFoundIndex, false
}

func findModerator(addr std.Address) int {
	for i, modAddr := range modAddrs {
		if modAddr == addr {
			return i
		}
	}

	return notFoundIndex
}

func assertAddrValid(addr std.Address) {
	// std.Address.IsValid() not available on test3
	_, _, ok := std.DecodeBech32(addr)
	if !ok {
		panic("Invalid wallet address")
	}
}

// assertIsModerator checks whether a current caller is owner or a moderator.
func assertIsModerator() {
	actorId := std.GetOrigCaller()
	isAllowed := actorId == ownerAddr || findModerator(actorId) != notFoundIndex
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
		Content:   stripHtml(message),
		CreatedAt: time.Now(),
	})

	nextID++
	return ufmt.Sprintf("Feedback submitted successfully with ID: %d", id)
}

// BanFeedback used by moderation team to remove feedbacks which violate code of conduct.
func BanFeedback(feedbackID int) string {
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
	feedback.Response = stripHtml(response)
	feedbacks[i] = feedback

	return "Response recorded successfully"
}

// GetRole returns a role name of a caller (admin, moderator or guest).
func GetRole() string {
	actorId := std.GetOrigCaller()
	if actorId == ownerAddr {
		return "admin"
	}

	if i := findModerator(actorId); i != notFoundIndex {
		return "moderator"
	}

	return "guest"
}

// AddModerator adds a new wallet address to a list of moderators.
func AddModerator(addr std.Address) string {
	assertIsOwner()
	assertAddrValid(addr)

	i := findModerator(addr)
	if i != notFoundIndex {
		panic("Entry already exists")
	}

	modAddrs = append(modAddrs, addr)
	return "Success"
}

// RemoveModerator removes a wallet address from a list of moderators.
func RemoveModerator(addr std.Address) string {
	assertIsOwner()
	assertAddrValid(addr)

	i := findModerator(addr)
	if i == notFoundIndex {
		panic("Entry not found")
	}

	modAddrs = append(modAddrs[:i], modAddrs[i+1:]...)
	return "Success"
}

// Render displays all feedback and responses.
func Render(path string) string {
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

		sb.WriteString("### Response\n")
		sb.WriteString(ufmt.Sprintf("At %s\n\n", fb.RespondAt.Format(time.RFC1123)))
		sb.WriteString(fb.Response)
		sb.WriteString("\n\n")
	}
	return sb.String()
}
