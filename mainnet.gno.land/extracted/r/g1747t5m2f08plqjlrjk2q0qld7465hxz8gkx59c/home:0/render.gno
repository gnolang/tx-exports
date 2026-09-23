package home

import (
	"strconv"
	"strings"

	"chain/runtime"
)

const (
	realmPath = "gno.land/r/g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c/home"
	webPath   = "/r/g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c/home"
)

// fallbackLayout renders when the layout slot is deleted.
const fallbackLayout = "# zôÖma\n\n:bio:\n\n:hearts:\n"

// Render serves:
//
//	""             the profile page
//	"slots"        the slot index
//	"slots/<slug>" one slot's raw markdown
//	"hearts"       everyone who sent a <3
func Render(path string) string {
	switch {
	case path == "":
		return renderPage()
	case path == "slots":
		return renderIndex()
	case strings.HasPrefix(path, "slots/"):
		return renderSlot(strings.TrimPrefix(path, "slots/"))
	case path == "hearts":
		return renderHearts()
	}
	return "# Not found\n\nNo such path: " + strconv.Quote(path) + "\n\n[Back home](" + webPath + ")\n"
}

func renderPage() string {
	layout := Get(layoutSlug)
	if layout == "" {
		layout = fallbackLayout
	}
	return fill(layout)
}

// fill replaces every :slug: in s, in one left-to-right pass. Replacement text
// is never rescanned, so a slot cannot expand into another slot. A placeholder
// with no value stays verbatim: a missing section should be visible.
func fill(s string) string {
	var b strings.Builder
	for {
		i := strings.IndexByte(s, ':')
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		b.WriteString(s[:i])
		s = s[i:]
		j := strings.IndexByte(s[1:], ':')
		if j < 0 {
			b.WriteString(s)
			return b.String()
		}
		slug := s[1 : j+1]
		if v, ok := lookup(slug); ok {
			b.WriteString(v)
			s = s[j+2:]
			continue
		}
		// Not a placeholder: emit the first ':' and rescan from the next one,
		// so "a:b :bio:" still finds :bio:.
		b.WriteString(":")
		s = s[1:]
	}
}

func lookup(slug string) (string, bool) {
	if !validSlug(slug) {
		return "", false
	}
	switch slug {
	case "chainid":
		return runtime.ChainID(), true
	case "height":
		return strconv.FormatInt(runtime.ChainHeight(), 10), true
	case "hearts":
		return heartsBlock(), true
	case "hero":
		return heroImage(), true
	case "realm":
		return realmPath, true
	case "rev":
		return strconv.Itoa(rev), true
	}
	if strings.HasPrefix(slug, galleryPrefix) {
		return renderGallery(strings.TrimPrefix(slug, galleryPrefix))
	}
	if v := slots.Get(slug); v != nil {
		return v.(*slot).body, true
	}
	return "", false
}

func heartsBlock() string {
	n := hearts.Size()
	var b strings.Builder
	b.WriteString("**")
	b.WriteString(strconv.Itoa(n))
	if n == 1 {
		b.WriteString("** heart so far.")
	} else {
		b.WriteString("** hearts so far.")
	}
	b.WriteString(" [Send yours](" + webPath + "$help&func=Heart): one transaction, one per address, forever on chain.")
	if len(recent) > 0 {
		b.WriteString("\n\nLatest: ")
		for i, a := range recent {
			if i > 0 {
				b.WriteString(" · ")
			}
			b.WriteString(userLink(a))
		}
		b.WriteString(" · [all](" + webPath + ":hearts)")
	}
	return b.String()
}

// userLink renders an address as a short link to its gno.land profile.
func userLink(a address) string {
	s := a.String()
	short := s
	if len(s) > 12 {
		short = s[:7] + "…" + s[len(s)-4:]
	}
	return "[" + short + "](/u/" + s + ")"
}

func renderHearts() string {
	var b strings.Builder
	b.WriteString("# <3\n\n")
	b.WriteString(strconv.Itoa(hearts.Size()) + " address(es) sent a heart. [Send yours](" + webPath + "$help&func=Heart).\n\n")
	if hearts.Size() == 0 {
		b.WriteString("_Be the first._\n")
		return b.String()
	}
	b.WriteString("| from | block |\n| --- | ---: |\n")
	hearts.Iterate("", "", func(key string, value any) bool {
		b.WriteString("| " + userLink(address(key)) + " | " + strconv.FormatInt(value.(int64), 10) + " |\n")
		return false
	})
	b.WriteString("\n[Back home](" + webPath + ")\n")
	return b.String()
}

func renderIndex() string {
	var b strings.Builder
	b.WriteString("# Slots\n\nrev " + strconv.Itoa(rev) + " · " + strconv.Itoa(slots.Size()) + " slot(s)\n\n")
	b.WriteString("| slot | bytes | rev | height |\n| --- | ---: | ---: | ---: |\n")
	slots.Iterate("", "", func(key string, value any) bool {
		s := value.(*slot)
		b.WriteString("| [" + key + "](" + webPath + ":slots/" + key + ") | " +
			strconv.Itoa(len(s.body)) + " | " + strconv.Itoa(s.rev) + " | " +
			strconv.FormatInt(s.updated, 10) + " |\n")
		return false
	})
	return b.String()
}

func renderSlot(slug string) string {
	v := slots.Get(slug)
	if v == nil {
		return "# Not found\n\nNo slot named " + strconv.Quote(slug) + ".\n\n[Slot index](" + webPath + ":slots)\n"
	}
	s := v.(*slot)
	body := s.body
	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	return "# " + slug + "\n\n" + strconv.Itoa(len(s.body)) + " bytes · rev " + strconv.Itoa(s.rev) +
		" · written at height " + strconv.FormatInt(s.updated, 10) + "\n\n````\n" + body + "````\n"
}
