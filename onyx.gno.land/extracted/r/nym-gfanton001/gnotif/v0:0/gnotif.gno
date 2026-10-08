// Package gnotif is a registry of notification triggers. Each trigger names
// a realm and an event type to watch, and the text of the notification that
// gnotif servers send when a matching event lands on chain. A later registry
// version follows the rules in
// https://gnotif.xyz/docs/how-it-works/#rules-for-a-new-registry-version.
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
	Declarer                                            address
	Verified                                            bool
}

const (
	targetPrefix   = "gno.land/r/"
	maxTarget      = 256
	maxName        = 64
	maxFilterPairs = 8
	maxBody        = 255
	maxLink        = 256
	maxPerTarget   = 64
)

var (
	triggers avl.Tree // id → *Trigger
	byTarget avl.Tree // target → *avl.Tree of id → *Trigger, verified triggers only
	lastID   seqid.ID
)

// Declare stores a trigger and returns its id. Only the target realm itself
// may declare a trigger for it.
func Declare(cur realm, target, event, filter, param, title, body, link string) string {
	validate(target, event, filter, param, title, body, link)
	caller := cur.Previous()
	verified := caller.IsCode() && caller.PkgPath() == target
	if !verified {
		panic("caller is not the target")
	}
	var own *avl.Tree
	if v := byTarget.Get(target); v != nil {
		own = v.(*avl.Tree)
	}
	if verified && own != nil && own.Size() >= maxPerTarget {
		panic("too many triggers for target")
	}
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
		Verified: verified,
	}
	triggers.Set(tr.ID, tr)
	if verified {
		if own == nil {
			own = avl.NewTree()
			byTarget.Set(target, own)
		}
		own.Set(tr.ID, tr)
	}
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
	tr := v.(*Trigger)
	if tr.Declarer != cur.Previous().Address() {
		panic("not the declarer")
	}
	triggers.Remove(id)
	if tr.Verified {
		own := byTarget.Get(tr.Target).(*avl.Tree)
		own.Remove(id)
		if own.Size() == 0 {
			byTarget.Remove(tr.Target)
		}
	}
	chain.Emit("TriggerRemoved", "id", id)
}

func validate(target, event, filter, param, title, body, link string) {
	switch {
	case !validTarget(target):
		panic("invalid target")
	case !validName(event, 1, maxName):
		panic("invalid event")
	case !validFilter(filter):
		panic("invalid filter")
	case !validName(param, 0, maxName):
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

// validTarget accepts a realm path whose segments each match the chain's
// Re_name, so a target names a path where a realm can exist.
func validTarget(target string) bool {
	if !strings.HasPrefix(target, targetPrefix) || len(target) > maxTarget {
		return false
	}
	rest := target[len(targetPrefix):]
	start := 0 // index of the current segment's first byte
	for i := 0; i <= len(rest); i++ {
		if i == len(rest) || rest[i] == '/' {
			if i == start || !isLowerAlnum(rest[i-1]) {
				return false
			}
			start = i + 1
			continue
		}
		c := rest[i]
		switch {
		case i == start:
			if !(c >= 'a' && c <= 'z') {
				return false
			}
		case c == '_' || c == '-':
			if !isLowerAlnum(rest[i-1]) {
				return false
			}
		case !isLowerAlnum(c):
			return false
		}
	}
	return true
}

func isLowerAlnum(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
}

// validName accepts identifier bytes only, so a name cannot carry spaces or
// symbols that imitate the verified mark in rendered output.
func validName(s string, lo, hi int) bool {
	if !sized(s, lo, hi) {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
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
		if !ok || !validName(key, 1, maxName) || !sized(value, 1, maxName) || strings.Contains(value, "=") {
			return false
		}
	}
	return true
}

// validLink accepts only a path, so a click always stays on the dapp's origin.
// "//host" starts with a slash yet resolves to another host. A URL parser
// drops tab, LF and CR and reads a backslash as a slash, so "/\t/host" and
// "/\host" would do the same; control bytes and backslashes are refused.
func validLink(link string) bool {
	if !sized(link, 1, maxLink) || !strings.HasPrefix(link, "/") || strings.HasPrefix(link, "//") {
		return false
	}
	for i := 0; i < len(link); i++ {
		if c := link[i]; c < 0x20 || c == 0x7f || c == '\\' {
			return false
		}
	}
	return true
}
