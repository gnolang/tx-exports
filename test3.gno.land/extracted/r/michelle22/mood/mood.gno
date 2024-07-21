package mood

var myMood = "my mood is"

func render(path string) string {
	return "My current mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "My mood was successfully updated"
}
