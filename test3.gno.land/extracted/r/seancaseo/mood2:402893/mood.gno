package mood

var myMood = "Looking forward to learn"

func Render(path string) string {
return "My current mood is" + myMood
}

func ChangeMyMood(newMood string){
 myMood = newMood
 return "Mood succesfully updated"
 
}

