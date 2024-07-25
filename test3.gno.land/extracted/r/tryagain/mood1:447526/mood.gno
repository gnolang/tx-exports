package mood1

var myMood = "my mood is"

fun Render(path string) string {
	return "My current mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "My mood was successfully updated"
}
