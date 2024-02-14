package poll

import (
    "strings"

    "gno.land/p/demo/ufmt"
)

var poll = Poll{
	Question: "What is your favorite color?",
	Cohices: []Cohice{
		{Name: "Blue"},
		{Name: "Red"},
		{Name: "Other"},
	},
}

type Poll struct {
	Question string
	Cohices  []Cohice
}

type Cohice struct {
	Name  string
	Count int
}

func Vote(cohice string) string {
    var found bool

    for i, c := range poll.Cohices {
        if strings.ToLower(cohice) == strings.ToLower(c.Name) {
            poll.Cohices[i].Count++
            found = true
            break
        }
    }

    if !found {
        return "Choice does not exist!"
    } else {
        return "Ok"
    }
}

func Render(path string) string {
    var md strings.Builder

    md.WriteString(ufmt.Sprintf("# %s\n", poll.Question)) // write question
    
    for _, c := range poll.Cohices { 
        md.WriteString(ufmt.Sprintf("- %s: %d\n", c.Name, c.Count)) // write choice
    }

    return md.String()
}