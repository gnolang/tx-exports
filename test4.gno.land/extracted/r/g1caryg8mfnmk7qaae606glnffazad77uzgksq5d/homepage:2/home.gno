package homepage

import (
	"gno.land/p/demo/ufmt"
)

var (
	pfp        string // link to profile picture
	pfpCaption string // profile picture caption
	abtMe      string
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
 
 Demonstrated ability to work collaboratively in team environments, as evidenced by participation in a large-scale group project to develop a banking web application, leveraging various frameworks to deliver robust backend functionalities.

Additionally, skilled in concurrent programming, showcased through the development of a small distributed system that simulates social media interactions, employing the Chord algorithm for efficient data handling.

In addition to my academic pursuits, I enjoy traveling and staying active through weightlifting. I have a keen interest in electronic music and often explore various genres. I believe in maintaining a balanced lifestyle that complements my professional development.`
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
	out := "# Matija's Homepage\n\n"

	out += renderAboutMe()
	out += "\n\n"
	out += renderGitHubProjects()

	return out
}

func renderAboutMe() string {
	out := "<div class='columns-2'>"

	out += "<div>\n\n"
	out += ufmt.Sprintf("![my profile pic](%s)\n\n%s\n\n", pfp, pfpCaption)
	out += "</div>\n\n"

	out += "<div>\n\n"
	out += abtMe + "\n\n"
	out += "</div>\n\n"

	out += "</div>\n\n"

	return out
}

func renderGitHubProjects() string{

	out := "# [Github Projects](https://github.com/matijamarjanovic)"

	out += "<div>\n\n"
	out += "[NUTRITION TRACKER ANDROID APP](https://github.com/matijamarjanovic/NutritionTrackerRMA)"
	out += "</div>\n\n"

	out += "<div>\n\n"
	out += "[DISTRIBUTED SYSTEM](https://github.com/RAF-KiDS/projekat-matijamarjanovic)"
	out += "</div>\n\n"

	out += "<div>\n\n"
	out += "[GROUP PROJECT - BANKING APP](https://github.com/matijamarjanovic/Banka-3-Backend)"
	out += "</div>\n\n"

	out += "<div>\n\n"
	out += "[FIAT CURRENCIES - DATA ANALYTICS](https://github.com/matijamarjanovic/BigData_CurrencyAnalitics)"
	out += "</div>\n\n"

	return out

}