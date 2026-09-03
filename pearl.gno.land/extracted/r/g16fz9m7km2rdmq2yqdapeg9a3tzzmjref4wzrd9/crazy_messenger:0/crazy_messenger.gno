package crazy_messenger

import "strconv"

type Message struct {
	From    string
	To      string
	Content string
}

var messages []Message

func Send(_ realm, from, to, content string) int {
	idx := len(messages)
	messages = append(messages, Message{From: from, To: to, Content: content})
	return idx
}

func TotalMessages() int {
	return len(messages)
}

func Render(_ string) string {
	out := "CRAZY MESSENGER - " + strconv.Itoa(len(messages)) + " messages\n"
	for i, m := range messages {
		out += "  #" + strconv.Itoa(i) + " " + m.From + " -> " + m.To + ": " + m.Content + "\n"
	}
	return out
}
