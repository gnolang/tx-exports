package mood

var myMood = "world"

func Render(path string)string 
{
 
    return "hello "+myMood 

}

func UpdateMood( newMood string) string {

    myMood = newMood

    return "OK"
}