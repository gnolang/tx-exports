package mood

var mymood = ""

func Render(path string) string {
	return "My mood is good " + mymood
}
func ChangeMyMood(mynewmood string) string {
	mymood = mynewmood
	return "sucessfully changed the mood"
}
