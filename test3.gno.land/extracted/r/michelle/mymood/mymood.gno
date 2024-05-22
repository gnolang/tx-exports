package mymood

var myMood = "loving Belgrade"

func Render(path string) string {
	return "My mood is " + myMood
}

func ChangeMyMood(newMood string) string {
	myMood = newMood
	return "Mood successfully changed"