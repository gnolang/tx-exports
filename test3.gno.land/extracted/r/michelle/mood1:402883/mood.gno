package mood

var myMood = "write you initial mood here"

func Render(path string) string {
	return "My mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "Mood successfully changed"
}
