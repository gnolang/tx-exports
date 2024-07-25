package mood

myMood := "Happy to be here"

func Render(path string) string {
    return "My mood is " + myMood
}

func ChangeMyMood(newMood string) string {
    myMood = newMood
    return "Mood updated"
}