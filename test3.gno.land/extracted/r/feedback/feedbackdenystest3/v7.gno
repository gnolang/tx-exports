package feedbackdenystest3

import (
    "avl"
    "std"
    "strings"
    "time"
    "gno.land/p/demo/ufmt"
)

const maxCharsCount = 256

type Feedback struct {
    ID        uint64
    User      std.Address
    Content   string
    Response  string
    CreatedAt time.Time
    RespondAt time.Time
}

var (
    nextID    uint64
    feedbacks *avl.Tree[uint64, Feedback]
    isLocked  = false
    ownerAddr = std.Address(
        "g1dnllrdzwfhxv3evyk09y48mgn5phfjvtyrlzm7",
    )
    modsAddrs = newAddrSet(
        "g1dnllrdzwfhxv3evyk09y48mgn5phfjvtyrlzm7",
    )
)

func init() {
    feedbacks = avl.NewTree[uint64, Feedback]()
    nextID = 0
}

func assertIsModerator() {
    actorId := std.GetOrigCaller()
    _, ok := modsAddrs[actorId]
    if actorId != ownerAddr && !ok {
        panic("Access Denied")
    }
}

func assertIsOwner() {
    actorId := std.GetOrigCaller()
    if actorId != ownerAddr {
        panic("Access Denied")
    }
}

func assertNotLocked() {
    if isLocked {
        panic("Realm is locked")
    }
}

func LockFeedback() string {
    assertIsOwner()
    isLocked = true
    return "Locked"
}

func UnlockFeedback() string {
    assertIsOwner()
    isLocked = false
    return "Unlocked"
}

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
    feedback := Feedback{
        ID:        id,
        User:      std.GetOrigCaller(),
        Content:   message,
        CreatedAt: time.Now(),
    }

    feedbacks.Set(id, feedback)
    nextID++
    return ufmt.Sprintf("Feedback submitted successfully with ID: %d", id)
}

func BanFeedback(feedbackID uint64) string {
    assertIsModerator()
    assertNotLocked()

    feedback, exists := feedbacks.Get(feedbackID)
    if !exists {
        panic("Feedback not found")
    }

    feedback.Content = ""
    feedbacks.Set(feedbackID, feedback)
    return "Feedback was removed by a moderator"
}

func RespondToFeedback(feedbackID uint64, response string) string {
    assertIsModerator()
    assertNotLocked()

    feedback, exists := feedbacks.Get(feedbackID)
    if !exists {
        panic("Feedback not found")
    }

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
    feedbacks.Set(feedbackID, feedback)

    return "Response recorded successfully"
}

func Render() string {
    var sb strings.Builder
    sb.WriteString("# Feedback Collection\n")
    feedbacks.Each(func(id uint64, fb Feedback) bool {
        sb.WriteString(ufmt.Sprintf("## Feedback #%d\n", id))
        sb.WriteString(ufmt.Sprintf("From `%s` at %s\n\n", fb.User, fb.CreatedAt.Format(time.RFC1123)))
        if fb.Content == "" {
            sb.WriteString("*Feedback was removed by a moderator*")
        } else {
            sb.WriteString(fb.Content)
        }
        sb.WriteString("\n")
        if fb.Response != "" {
            sb.WriteString("### Response")
            sb.WriteString(ufmt.Sprintf("At %s\n\n", fb.RespondAt.Format(time.RFC1123)))
            sb.WriteString(fb.Response)
            sb.WriteString("\n\n")
        }
        return true
    })
    return sb.String()
}
