package mymood

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

var mymoodboardtest
var nextID = 1

// SubmitMood allows users to submit how they feel.
func SubmitMood(content string) string {
    user := std.GetOrigCaller()
    feedback := mymoodboard{ID: nextID, User: user, Content: content}
    feedbackList = append(mymood))
    nextID++
    return ufmt.Sprintf("The mood has been successfully shared, feedback.ID)
}

// RespondwithMood  allows any user to respond with their mood.
func RespondwithMood(feedbackID int, response string) string {
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