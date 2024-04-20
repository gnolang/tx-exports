package mymood

import (
	"gno.land/p/demo/ufmt"
	"std"
	"strings"
)

type Mood struct {
	ID       int
	User     std.Address
	Content  string
	Response string
}

var moodList []Mood
var nextID = 1

// SubmitMood allows users to submit their mood.
func SubmitMood(content string) string {
	user := std.GetOrigCaller()
	mood := Mood{ID: nextID, User: user, Content: content}
	moodList = append(moodList, mood)
	nextID++
	return ufmt.Sprintf("Your mood has been successfully shared, ID: %d", mood.ID)
}

// UpdateMood allows users to update their mood.
func UpdateMood(moodID int, content string) string {
	for i, m := range moodList {
		if m.ID == moodID {
			moodList[i].Content = content
			return ufmt.Sprintf("Your mood (ID: %d) has been successfully updated", moodID)
		}
	}
	return "Mood ID not found"
}

// RespondToMood allows any user to respond to a mood.
func RespondToMood(moodID int, response string) string {
	for i, m := range moodList {
		if m.ID == moodID {
			moodList[i].Response = response
			return "Response added successfully"
		}
	}
	return "Mood ID not found"
}

// RenderMoods displays all moods and responses.
func RenderMoods(path string) string {
	var output strings.Builder
	output.WriteString("# Mood Collection\n")
	for _, m := range moodList {
		output.WriteString(ufmt.Sprintf("## Mood ID: %d\n", m.ID))
		output.WriteString(ufmt.Sprintf("- User: %s\n", m.User))
		output.WriteString(ufmt.Sprintf("- Mood: %s\n", m.Content))
		if m.Response != "" {
			output.WriteString(ufmt.Sprintf("- Response: %s\n", m.Response))
		} else {
			output.WriteString("- Response: Pending\n")
		}
		output.WriteString("\n")
	}
	return output.String()
}
