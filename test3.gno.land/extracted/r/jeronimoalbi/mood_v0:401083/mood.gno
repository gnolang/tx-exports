package mood_v0

var myMood = "write your mood here"

func Render(path string) string {
	return "My current mood is " + myMood
}

func SetMyMood(newMood string) string {
	myMood = newMood
	return "Mood successfully changed"
}
