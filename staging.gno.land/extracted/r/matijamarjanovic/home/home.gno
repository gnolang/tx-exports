package home

import (
	"std"
	//"gno.land/p/demo/avl"
	"gno.land/p/demo/ufmt"
	"gno.land/r/matijamarjanovic/config"
	"gno.land/r/matijamarjanovic/snakeart"

)

var (
	pfp          string // link to profile picture
	pfpCaption   string // profile picture caption
	abtMe      	 string
	currentColor string

)

func init() {
	pfp = "https://muaythairecords.com/fighters/rodtang-jitmuangnon/ogimage"
	pfpCaption = "My profile picture - Rodtang Jitmuangnon (Muay Thai fighter)"
	abtMe = 
		`### About me
 Motivated Computer Science student with strong
 analytical and problem-solving skills. Proficient in
 programming and version control, with a high level of
 focus and attention to detail. Eager to apply academic
 knowledge to real-world projects and contribute to
 innovative technology solutions.

In addition to my academic pursuits, I enjoy traveling and staying active through weightlifting. I have a keen interest in electronic music and often explore various genres. I believe in maintaining a balanced lifestyle that complements my professional development.`
currentColor = `rgba(120, 0, 0)`
}

func UpdatePFP(url, caption string) {
	AssertAuthorized()
	pfp = url
	pfpCaption = caption
}

func UpdateAboutMe(col1 string) {
	AssertAuthorized()
	abtMe = col1
}

func Render(path string) string {

	if(std.GetHeight() % 2 == 1){
		currentColor = `rgb(120, 0, 0)`
	}else if(std.GetHeight() % 2 == 0){
		currentColor = `rgb(0, 0, 120)`
	}else if(std.GetHeight() % 2 == 2){
		currentColor = `rgn(0, 120, 0)`
	}

	out := ufmt.Sprintf("<div style='font-family: \"Trebuchet MS\", sans-serif;font-size: 5rem; text-shadow: 5px 5px 0px %s;'>\n\n",currentColor)
	out += ufmt.Sprintf("# Matija's Homepage %s\n\n", "")
	out += "</div>\n\n"
	out += "<div style='font-family: \"Trebuchet MS\", sans-serif; text-align: justify;'>\n\n"
	out += renderAboutMe()
	out += "\n\n"
	out += renderGitHubProjects()
	out += renderArt()
	out += "</div>\n\n"

	return out
}

func renderAboutMe() string {
	out := "<div class='columns-2'>"

	out += "<div>\n\n"
	out += ufmt.Sprintf(
		`<img src='%s' alt='Profile Picture' style='border-radius: 50%%; width: 200px; transition: transform 0.3s ease; outline: 2px solid %s;' />`, 
		pfp, currentColor)
	out += ufmt.Sprintf("<p>%s</p>\n\n", pfpCaption)
	out += "</div>\n\n"

	out += "<div>\n\n"
	out += abtMe + "\n\n"
	out += "</div>\n\n"

	out += "</div>\n\n"


	return out
}

func renderGitHubProjects() string{

	
	out := ufmt.Sprintf("<div style = 'text-shadow: 5px 5px 0px %s;'>\n\n", currentColor)
	out += "### [Github](https://github.com/matijamarjanovic)"
	out += "</div>\n\n\n\n\n"

	return out

}

func renderArt() string{
	out := "<div>\n\n"
	out += "```\n" + DrawSnake(int(std.GetHeight())%10+5) + "```\n"
	out += "</div>\n\n"

	return out
}