package moodtest

var myMood = "building my first tutorial"

func Render(path string) string {
	return "My mood is " + myMood
}

func ChangeMyMood(myNewMood string) string {
	myMood = myNewMood
	return "Successfully changed my mood"
}
