package simplefeedback

import (
    "gno.land/p/demo/ufmt"
    "std"
    "strings"
)

type Feedback struct {
    ID       int
    User     std.Address
    Content  string
    Response string
}

var feedbackList []Feedback
var nextID = 1

// SubmitFeedback allows users to submit feedback.
func SubmitFeedback(content string) string {
    user := std.GetOrigCaller()
    feedback := Feedback{ID: nextID, User: user, Content: content}
    feedbackList = append(feedbackList, feedback)
    nextID++
    return ufmt.Sprintf("Feedback submitted successfully with ID: %d", feedback.ID)
}

// RespondToFeedback allows any user to respond to a feedback.
func RespondToFeedback(feedbackID int, response string) string {
    for i, fb := range feedbackList {
        if fb.ID == feedbackID {
            feedbackList[i].Response = response
            return "Response added successfully"
        }
    }
    return "Feedback ID not found"
}

// Render displays all feedback and responses.
func Render(path string) string {
    var output strings.Builder
    output.WriteString("# Feedback Collection\n")
    for _, fb := range feedbackList {
        output.WriteString(ufmt.Sprintf("## Feedback ID: %d\n", fb.ID))
        output.WriteString(ufmt.Sprintf("- User: %s\n", fb.User))
        output.WriteString(ufmt.Sprintf("- Content: %s\n", fb.Content))
        if fb.Response != "" {
            output.WriteString(ufmt.Sprintf("- Response: %s\n", fb.Response))
        } else {
            output.WriteString("- Response: Pending\n")
        }
        output.WriteString("\n")
    }
    return output.String()
}
