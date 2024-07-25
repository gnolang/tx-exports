package mood_v1

var myMood = "ready for the weekend"

func Render(string) string {
	return "My mood is " + myMood
}

func SetMyMood(newMood string) string {
	myMood = newMood
	return "my mood was changed"
}
