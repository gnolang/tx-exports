package forms

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
)

// Submit records a response to a form. Answers a1..a8 align with the form's
// fields in order; slots beyond the form's field count must be empty.
//
// gnoweb builds this call from the rendered form: each input is named after
// the parameter it fills, and parameters with no input arrive as "".
//
// The respondent pays the storage deposit for their own answers, and gets it
// back on Withdraw.
func Submit(cur realm, id string, a1, a2, a3, a4, a5, a6, a7, a8 string) {
	author := mustUserCaller(cur)
	f := mustGetForm(id)
	height := runtime.ChainHeight()

	if !f.IsOpen(height) {
		if f.Deadline > 0 && height >= f.Deadline {
			panic(ErrDeadlinePassed)
		}
		panic(ErrFormClosed)
	}

	if f.OnePerAddr && f.byAddr.Has(author.String()) {
		panic(ErrAlreadyResponded)
	}

	answers := validateAnswers(f, []string{a1, a2, a3, a4, a5, a6, a7, a8})

	rid := nextRespID.Next()
	r := &Response{
		ID:      rid,
		Form:    f.ID,
		Author:  author,
		Height:  height,
		Answers: answers,
	}

	f.responses.Set(rid.String(), r)
	f.byAddr.Set(author.String(), rid.String())

	chain.Emit("ResponseSubmitted", "form", id, "response", rid.String(), "author", author.String())
}

// Withdraw deletes the caller's response to a form. The storage deposit the
// answers were holding is refunded to the caller by the chain.
//
// Only the author can withdraw. Owners cannot delete responses: the refund
// goes to whoever deletes, which would hand the owner the respondent's
// deposit.
func Withdraw(cur realm, id string) {
	author := mustUserCaller(cur)
	f := mustGetForm(id)

	raw := f.byAddr.Get(author.String())
	if raw == nil {
		panic(ErrNoResponse)
	}
	rid := raw.(string)

	f.responses.Remove(rid)
	f.byAddr.Remove(author.String())

	chain.Emit("ResponseWithdrawn", "form", id, "response", rid, "author", author.String())
}

// validateAnswers checks every answer against its field and returns the
// trimmed answers, exactly len(f.Fields) long. Nothing is written before it
// returns, so a rejected submission leaves no trace.
func validateAnswers(f *Form, raw []string) []string {
	n := len(f.Fields)

	for i := n; i < len(raw); i++ {
		if strings.TrimSpace(raw[i]) != "" {
			panic(ErrTooManyAnswers)
		}
	}

	answers := make([]string, n)
	for i, field := range f.Fields {
		a := strings.TrimSpace(raw[i])

		if a == "" {
			if field.Required {
				panic(fieldErr(i, ErrRequired))
			}
			answers[i] = ""
			continue
		}

		if len(a) > field.MaxLen() {
			panic(fieldErr(i, ErrAnswerTooLong))
		}

		switch field.Kind {
		case KindNumber:
			if _, err := strconv.ParseFloat(a, 64); err != nil {
				panic(fieldErr(i, ErrNotANumber))
			}
		case KindSelect:
			if !contains(field.Options, a) {
				panic(fieldErr(i, ErrNotAnOption))
			}
		}

		answers[i] = a
	}

	return answers
}

func fieldErr(i int, err error) string {
	return "field " + strconv.Itoa(i+1) + ": " + err.Error()
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}

	return false
}
