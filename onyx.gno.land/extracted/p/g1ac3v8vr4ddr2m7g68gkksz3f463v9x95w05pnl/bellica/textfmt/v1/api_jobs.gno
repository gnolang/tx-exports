package textfmt

import (
	"strconv"
	"strings"
)

func Ts(t interface{ Unix() int64 }) string { return I64(t.Unix()) }

func UnixOr0(t interface {
	IsZero() bool
	Unix() int64
}) string {
	if t.IsZero() {
		return "0"
	}
	return I64(t.Unix())
}

func DeliverJSON(kind, url, hash, text, note string, at interface {
	IsZero() bool
	Unix() int64
}) string {
	if at.IsZero() {
		return "null"
	}
	return `{"kind":` + Jq(kind) + `,"url":` + Jq(url) + `,"sha256":` + Jq(hash) + `,"text":` + Jq(text) + `,"note":` + Jq(note) + `,"at_unix":` + I64(at.Unix()) + `}`
}

func IdsJSON(t interface{ Get(string) any }, k string) string {
	ids, _ := t.Get(k).([]int)
	q := make([]string, len(ids))
	for i, id := range ids {
		q[i] = strconv.Itoa(id)
	}
	return "[" + strings.Join(q, ",") + "]"
}

func BadgesJSON(bs []string) string {
	q := make([]string, len(bs))
	for i, b := range bs {
		q[i] = Jq(b)
	}
	return "[" + strings.Join(q, ",") + "]"
}
