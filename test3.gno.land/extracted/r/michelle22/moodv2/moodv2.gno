package moodv2

var myMood = "loving Belgrade"

func Render(path string) string { return "my current mood is " + myMood }

func ChangeMyMood(newMood string) {
	myMood = newMood

	return "My mood is successfully updated"
}
