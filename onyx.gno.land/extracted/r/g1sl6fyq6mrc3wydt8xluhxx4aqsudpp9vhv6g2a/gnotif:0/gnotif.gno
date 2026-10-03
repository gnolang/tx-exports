// Package gnotif is a registry of notification triggers. Each trigger names
// a realm and an event type to watch, and the text of the notification that
// gnotif servers send when a matching event lands on chain.
package gnotif

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Trigger is one declared notification rule. Filter holds comma-separated
// key=value pairs; Title, Body and Link are templates where {key} stands for
// the value of the event's attribute key.
type Trigger struct {
	ID, Target, Event, Filter, Param, Title, Body, Link string
	Declarer address
	Verified bool
}

const (
	targetPrefix   = "gno.land/r/"
	maxTarget      = 256
	maxName        = 64
	maxFilterPairs = 8
	maxBody        = 255
	maxLink        = 256
)

var (
	triggers avl.Tree // id → *Trigger
	lastID   seqid.ID
)

// Declare stores a trigger and returns its id. The trigger is verified when
// its caller is the target realm itself.
func Declare(cur realm, target, event, filter, param, title, body, link string) string {
	validate(target, event, filter, param, title, body, link)
	caller := cur.Previous()
	tr := &Trigger{
		ID:       lastID.Next().String(),
		Target:   target,
		Event:    event,
		Filter:   filter,
		Param:    param,
		Title:    title,
		Body:     body,
		Link:     link,
		Declarer: caller.Address(),
		Verified: caller.IsCode() && caller.PkgPath() == target,
	}
	triggers.Set(tr.ID, tr)
	chain.Emit("TriggerDeclared",
		"id", tr.ID,
		"target", tr.Target,
		"event", tr.Event,
		"filter", tr.Filter,
		"param", tr.Param,
		"title", tr.Title,
		"body", tr.Body,
		"link", tr.Link,
		"declarer", tr.Declarer.String(),
		"verified", strconv.FormatBool(tr.Verified),
	)
	return tr.ID
}

// Remove deletes a trigger. Only its declarer may remove it.
func Remove(cur realm, id string) {
	v := triggers.Get(id)
	if v == nil {
		panic("unknown trigger")
	}
	if v.(*Trigger).Declarer != cur.Previous().Address() {
		panic("not the declarer")
	}
	triggers.Remove(id)
	chain.Emit("TriggerRemoved", "id", id)
}

func validate(target, event, filter, param, title, body, link string) {
	switch {
	case !strings.HasPrefix(target, targetPrefix) || len(target) > maxTarget:
		panic("invalid target")
	case !sized(event, 1, maxName):
		panic("invalid event")
	case !validFilter(filter):
		panic("invalid filter")
	case !sized(param, 0, maxName):
		panic("invalid param")
	case !sized(title, 1, maxName):
		panic("invalid title")
	case !sized(body, 0, maxBody):
		panic("invalid body")
	case !validLink(link):
		panic("invalid link")
	}
}

func sized(s string, lo, hi int) bool {
	return len(s) >= lo && len(s) <= hi
}

func validFilter(filter string) bool {
	if filter == "" {
		return true
	}
	pairs := strings.Split(filter, ",")
	if len(pairs) > maxFilterPairs {
		return false
	}
	for _, pair := range pairs {
		key, value, ok := strings.Cut(pair, "=")
		if !ok || !sized(key, 1, maxName) || !sized(value, 1, maxName) || strings.Contains(value, "=") {
			return false
		}
	}
	return true
}

// validLink accepts only a path, so a click always stays on the dapp's origin.
// "//host" and "/\host" start with a slash yet resolve to another host.
func validLink(link string) bool {
	return sized(link, 1, maxLink) &&
		strings.HasPrefix(link, "/") &&
		!strings.HasPrefix(link, "//") &&
		!strings.HasPrefix(link, "/\\")
}
