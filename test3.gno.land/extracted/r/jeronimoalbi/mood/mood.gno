package mood

var myMood = "looking forward to learn"

func Render(path string) string {
	return "My current mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "Mood succesfully updated"
}
