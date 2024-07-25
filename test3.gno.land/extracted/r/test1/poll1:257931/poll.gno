package poll1

// improvement ideas:
// make it time limited
// one vote per user

import (
    "gno.land/p/demo/ufmt"
    "strings"
)

var poll = Poll{
	Name: "What is your favorite color?",
	Cohices: []Cohice{
		{Name: "Blue"},
		{Name: "Red"},
		{Name: "Green"},
		{Name: "Purple"},
		{Name: "Black"},
		{Name: "Pink"},
		{Name: "Gray"},
		{Name: "Yellow"},
		{Name: "White"},
		{Name: "Orange"},
		{Name: "Brown"},
		{Name: "Other"},
	},
}

type Poll struct {
	Name    string
	Cohices []Cohice
}

type Cohice struct {
	Name  string
	Count int
}

func Vote(cohice string) string {
    var found bool

    for _, c := range poll.Cohices {
        if strings.ToLower(cohice) == strings.ToLower(c.Name) {
            c.Count++
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

    md.WriteString(ufmt.Sprintf("# %s\n", poll.Name)) // write question
    
    for _, c := range poll.Cohices { 
        md.WriteString(ufmt.Sprintf("- %s: %d\n", c.Name, c.Count)) // write choice
    }

    return md.String()
}