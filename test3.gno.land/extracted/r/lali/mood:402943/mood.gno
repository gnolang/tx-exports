package mood

var myMood = "Why haven't I won the lottery"

func Render(path string) string {
	return "My current mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "Mood successfully updated"
}
