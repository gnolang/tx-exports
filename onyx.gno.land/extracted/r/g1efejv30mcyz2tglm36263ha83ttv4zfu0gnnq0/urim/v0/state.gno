package urim

import (
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
)

// State returns one draw's public state as JSON, for phones to read with a
// vm/qeval query. It holds exactly what the chain already shows; nothing in
// it links a slot or slip to a person.
func State(id int64) string {
	v := draws.Get(key(id))
	if v == nil {
		return "null"
	}
	d := v.(*draw)
	h := d.hat
	var b strings.Builder
	b.WriteString("{")
	field(&b, "id", strconv.FormatInt(d.id, 10))
	field(&b, "title", strconv.Quote(d.title))
	field(&b, "budget", strconv.Quote(d.budget))
	field(&b, "date", strconv.Quote(d.date))
	field(&b, "live", strconv.FormatBool(d.live))
	field(&b, "organiser", strconv.Quote(hex.EncodeToString(d.organiser)))
	field(&b, "phase", strconv.Quote(h.Phase().String()))
	field(&b, "deadline", strconv.FormatInt(h.Deadline().Unix(), 10))
	field(&b, "turn", strconv.Itoa(h.Turn()))
	field(&b, "expected", strconv.Itoa(h.Expected()))
	field(&b, "count", strconv.Itoa(h.Count()))
	field(&b, "completed", strconv.FormatBool(h.Completed()))
	field(&b, "reason", strconv.Quote(h.Reason()))
	field(&b, "next", strconv.FormatInt(d.next, 10))
	field(&b, "seed", strconv.Quote(hex.EncodeToString(h.Seed())))

	people := make([]string, len(d.people))
	for i, p := range d.people {
		people[i] = "{\"name\":" + strconv.Quote(p.name) +
			",\"sign\":\"" + hex.EncodeToString(p.signPub) +
			"\",\"box\":\"" + hex.EncodeToString(p.boxPub) +
			"\",\"done\":" + strconv.FormatBool(h.Done(i)) + "}"
	}
	field(&b, "people", "["+strings.Join(people, ",")+"]")

	sh := make([]string, len(h.Shufflers()))
	for t, s := range h.Shufflers() {
		sh[t] = strconv.Itoa(s)
	}
	field(&b, "shufflers", "["+strings.Join(sh, ",")+"]")
	field(&b, "contents", list(h.Contents(), base64.StdEncoding.EncodeToString))
	field(&b, "slots", list(h.Slots(), hex.EncodeToString))
	b.WriteString("\"slips\":" + list(h.Slips(), base64.StdEncoding.EncodeToString) + "}")
	return b.String()
}

// Stats returns the public counter as JSON.
func Stats() string {
	return "{\"completed\":" + strconv.Itoa(completed) + ",\"people\":" + strconv.Itoa(people) +
		",\"voided\":" + strconv.Itoa(voided) + ",\"draws\":" + strconv.FormatInt(lastID, 10) + "}"
}

func field(b *strings.Builder, name, value string) {
	b.WriteString("\"" + name + "\":" + value + ",")
}

func list(items [][]byte, enc func([]byte) string) string {
	out := make([]string, len(items))
	for k, it := range items {
		out[k] = "\"" + enc(it) + "\""
	}
	return "[" + strings.Join(out, ",") + "]"
}
