package gnotif

import (
	"strconv"
	"strings"
)

const recordFields = 8

// record is a trigger, its target and its name as the registry stores them:
// one string per trigger, because a tree holds a string inline and a struct
// is one more stored object.
type record struct {
	Target string
	Name   string
	T      Trigger
}

func (r record) encode() string {
	return packFields(r.Target, r.Name, r.T.Event, r.T.Filter, r.T.Param, r.T.Title, r.T.Body, r.T.Link)
}

// decodeRecord reads a string made by encode and panics on any other.
func decodeRecord(v any) record {
	f := unpackFields(v.(string), recordFields)
	return record{
		Target: f[0],
		Name:   f[1],
		T:      Trigger{Event: f[2], Filter: f[3], Param: f[4], Title: f[5], Body: f[6], Link: f[7]},
	}
}

// packFields writes each field as its byte length, a colon and the field, so
// a field may hold colons and digits.
func packFields(fields ...string) string {
	var b strings.Builder
	for _, f := range fields {
		b.WriteString(strconv.Itoa(len(f)) + ":" + f)
	}
	return b.String()
}

// unpackFields reads exactly n fields made by packFields and panics on any
// other string.
func unpackFields(s string, n int) []string {
	fields := make([]string, n)
	for i := range fields {
		field, rest, ok := cutField(s)
		if !ok {
			panic("corrupt record")
		}
		fields[i], s = field, rest
	}
	if s != "" {
		panic("corrupt record")
	}
	return fields
}

func cutField(s string) (field, rest string, ok bool) {
	length, body, found := strings.Cut(s, ":")
	if !found {
		return "", "", false
	}
	n, err := strconv.Atoi(length)
	if err != nil || n < 0 || n > len(body) {
		return "", "", false
	}
	return body[:n], body[n:], true
}
