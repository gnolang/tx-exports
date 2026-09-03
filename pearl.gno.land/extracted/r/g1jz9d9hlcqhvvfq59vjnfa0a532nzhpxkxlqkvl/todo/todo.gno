package todo

import "strconv"

type Task struct {
	Text string
	Done bool
}

var todos map[string][]Task

func init() {
	todos = make(map[string][]Task)
}

func Add(user, text string) int {
	todos[user] = append(todos[user], Task{Text: text})
	return len(todos[user]) - 1
}

func Complete(user string, idx int) {
	t := todos[user]
	if idx < 0 || idx >= len(t) {
		panic("invalid index")
	}
	t[idx].Done = true
}

func List(user string) string {
	out := "todos for " + user + ":\n"
	for i, t := range todos[user] {
		status := "[ ]"
		if t.Done {
			status = "[x]"
		}
		out += "  " + strconv.Itoa(i) + ". " + status + " " + t.Text + "\n"
	}
	return out
}

func Render(_ string) string {
	total := 0
	for _, ts := range todos {
		total += len(ts)
	}
	return "todo realm - " + strconv.Itoa(total) + " tasks total\n"
}
