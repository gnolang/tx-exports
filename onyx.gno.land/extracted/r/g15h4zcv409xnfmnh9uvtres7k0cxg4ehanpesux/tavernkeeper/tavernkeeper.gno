// Package tavernkeeper is the AI Tavern Keeper realm for the
// Gnome Tavern Hackathon (Gno.land, DoraHacks, Dec 2026).
//
// Anyone can ask the Keeper a question. An off-chain Keeper service
// (see ../keeper) answers with an LLM and records the answer on-chain.
// Anyone can tip the Keeper in ugnot for a good answer. Every question,
// answer and tip lives on-chain forever.
//
// Flow:
//  1. AskQuestion(text)            -> returns the question id
//  2. AnswerQuestion(id, answer)   -> first answer wins, recorded on-chain
//  3. Tip(id) with -send <n>ugnot -> forwards the tip to the answerer
//
// View helpers (read-only, for frontends):
//
//	GetQuestion(id), ListQuestions(), GetStats() return JSON strings.
//	Render(path) renders the tavern for gnoweb.
package tavernkeeper

import (
	"banker"
	"chain"
	"runtime"
	"strconv"
	"strings"
	"unsafe"
)

// Question is one tavern exchange.
type Question struct {
	ID         int
	Asker      address
	Text       string
	Answer     string
	AnsweredBy address
	Answered   bool
	Tips       int64 // total ugnot tipped for this answer
	Height     int64 // block height when asked
}

var (
	// questions holds every question ever asked, in order.
	questions []Question
	// totalTips is the sum of all ugnot ever tipped to Keepers.
	totalTips int64
)

// AskQuestion records a new question and returns its id.
func AskQuestion(cur realm, text string) int {
	runtime.AssertOriginCall()
	text = strings.TrimSpace(text)
	if text == "" {
		panic("question must not be empty")
	}
	if len(text) > 500 {
		panic("question must be at most 500 characters")
	}
	caller := unsafe.OriginCaller()
	id := len(questions)
	questions = append(questions, Question{
		ID:     id,
		Asker:  caller,
		Text:   text,
		Height: runtime.ChainHeight(),
	})
	chain.Emit("QuestionAsked", "id", strconv.Itoa(id), "asker", caller.String())
	return id
}

// AnswerQuestion records an answer for an unanswered question.
// Anyone may answer; the first answer wins and is final. In practice the
// Keeper service (an LLM) answers within seconds of a new question.
func AnswerQuestion(cur realm, id int, answer string) {
	runtime.AssertOriginCall()
	answer = strings.TrimSpace(answer)
	if answer == "" {
		panic("answer must not be empty")
	}
	if len(answer) > 2000 {
		panic("answer must be at most 2000 characters")
	}
	if id < 0 || id >= len(questions) {
		panic("unknown question")
	}
	if questions[id].Answered {
		panic("question already answered")
	}
	caller := unsafe.OriginCaller()
	questions[id].Answer = answer
	questions[id].AnsweredBy = caller
	questions[id].Answered = true
	chain.Emit("QuestionAnswered", "id", strconv.Itoa(id), "answerer", caller.String())
}

// Tip forwards ugnot to the Keeper who answered the question.
// Call with funds, e.g. gnokey maketx call ... -send 1000000ugnot.
// Only answered questions can be tipped.
func Tip(cur realm, id int) {
	runtime.AssertOriginCall()
	if id < 0 || id >= len(questions) {
		panic("unknown question")
	}
	if !questions[id].Answered {
		panic("cannot tip an unanswered question")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("tip must include ugnot")
	}
	caller := unsafe.OriginCaller()
	b := banker.NewBanker(banker.BankerTypeOriginSend, cur)
	b.SendCoins(caller, questions[id].AnsweredBy, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	questions[id].Tips += amount
	totalTips += amount
	chain.Emit("TipReceived", "id", strconv.Itoa(id), "from", caller.String(), "amount", strconv.FormatInt(amount, 10))
}

// GetQuestion returns one question as a JSON string, or "" if unknown.
func GetQuestion(id int) string {
	if id < 0 || id >= len(questions) {
		return ""
	}
	return questionJSON(questions[id])
}

// ListQuestions returns all questions as a JSON array string.
func ListQuestions() string {
	out := "["
	for i, q := range questions {
		if i > 0 {
			out += ","
		}
		out += questionJSON(q)
	}
	out += "]"
	return out
}

// GetStats returns tavern stats as a JSON string.
func GetStats() string {
	answered := 0
	for _, q := range questions {
		if q.Answered {
			answered++
		}
	}
	return "{\"totalQuestions\":" + strconv.Itoa(len(questions)) +
		",\"answered\":" + strconv.Itoa(answered) +
		",\"totalTipsUgnot\":" + strconv.FormatInt(totalTips, 10) + "}"
}

// Render shows the tavern on gnoweb.
func Render(path string) string {
	s := "# 🍺 AI Tavern Keeper\n\n"
	s += "Ask the Keeper anything. The Keeper — an LLM — answers, and every question, answer and tip is recorded on-chain.\n\n"
	s += "## Questions\n\n"
	if len(questions) == 0 {
		s += "_No questions yet. Be the first to ask!_\n"
	}
	for _, q := range questions {
		s += "### #" + strconv.Itoa(q.ID) + " — " + q.Text + "\n\n"
		s += "Asked by `" + q.Asker.String() + "` at height " + strconv.FormatInt(q.Height, 10) + ".\n\n"
		if q.Answered {
			s += "**Keeper:** " + q.Answer + "\n\n"
			s += "Answered by `" + q.AnsweredBy.String() + "`. Tips: " + strconv.FormatInt(q.Tips, 10) + " ugnot.\n\n"
		} else {
			s += "_Awaiting the Keeper's answer..._\n\n"
		}
	}
	s += "---\n\n"
	s += "Total questions: " + strconv.Itoa(len(questions)) + " · Total tips: " + strconv.FormatInt(totalTips, 10) + " ugnot.\n"
	return s
}

// questionJSON renders one Question as JSON. Built by hand because
// encoding/json is not available in Gno.
func questionJSON(q Question) string {
	return "{\"id\":" + strconv.Itoa(q.ID) +
		",\"asker\":\"" + q.Asker.String() + "\"" +
		",\"text\":\"" + jsonEscape(q.Text) + "\"" +
		",\"answer\":\"" + jsonEscape(q.Answer) + "\"" +
		",\"answeredBy\":\"" + q.AnsweredBy.String() + "\"" +
		",\"answered\":" + strconv.FormatBool(q.Answered) +
		",\"tipsUgnot\":" + strconv.FormatInt(q.Tips, 10) +
		",\"height\":" + strconv.FormatInt(q.Height, 10) + "}"
}

// jsonEscape escapes a string for inclusion in JSON output.
func jsonEscape(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '"' {
			out += "\\\""
		} else if c == '\\' {
			out += "\\\\"
		} else if c == '\n' {
			out += "\\n"
		} else if c == '\r' {
			out += "\\r"
		} else if c == '\t' {
			out += "\\t"
		} else if c < 0x20 {
			out += " "
		} else {
			out += string([]byte{c})
		}
	}
	return out
}
