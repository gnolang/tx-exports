package mood_v01

var myMood = "looking forward to learn"

func Render(path string) string {
	return "My mood is " + myMood
}

func SetMyMood(newMood string) string {
	myMood = newMood
	return "Mood successfully changed"
}
