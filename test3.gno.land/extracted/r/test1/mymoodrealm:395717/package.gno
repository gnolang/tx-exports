package mymoodrealm

var myMood = "empty"

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "My mood has changed"
}

func Render(path string) string {
	return "My Mood is " + myMood
}
