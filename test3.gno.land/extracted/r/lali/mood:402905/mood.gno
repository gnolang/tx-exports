package mood

var myMood = "Why haven't I won the lottery 🤣"

func Render(path string) string {
    return "My current modd is " + myMood
}

Func ChangeMyMood(newMood string) string {
    myMood = newMood
    return "Mood succesfully updated"
}
