package mood

var myMood

myMood = "world"

func Render(path string)string 
{
 
    return "hello "+myMood 

}

func UpdateMood( newMood string) string {

    myMood = newMood

    return "OK"
}