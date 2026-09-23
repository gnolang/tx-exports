package home

import (
	"strconv"
	"strings"

	"chain/runtime"
)

const (
	realmPath = "gno.land/r/samcrew/home"
	webPath   = "/r/samcrew/home"
)

const fallbackLayout = "# samcrew\n\n:intro:\n\n## The crew\n\n:crew:\n"

// Render serves:
//
//	""             the team page
//	"slots"        the slot index
//	"slots/<slug>" one slot's raw markdown
func Render(path string) string {
	switch {
	case path == "":
		return renderPage()
	case path == "slots":
		return renderIndex()
	case strings.HasPrefix(path, "slots/"):
		return renderSlot(strings.TrimPrefix(path, "slots/"))
	}
	// The path is not echoed: it comes from the visitor's URL.
	return "# Not found\n\nThis page does not exist.\n\n[Back home](" + webPath + ")\n"
}

func renderPage() string {
	layout := Get(layoutSlug)
	if layout == "" {
		layout = fallbackLayout
	}
	return fill(layout)
}

// fill replaces every :slug: in s, in one left-to-right pass. Replacement text
// is never rescanned, and an unknown placeholder stays verbatim.
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
		if v, ok := lookup(s[1 : j+1]); ok {
			b.WriteString(v)
			s = s[j+2:]
			continue
		}
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
	case "crew":
		return crewTable(), true
	case "hero":
		return heroImage(), true
	case "height":
		return strconv.FormatInt(runtime.ChainHeight(), 10), true
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

func renderIndex() string {
	var b strings.Builder
	b.WriteString("# Slots\n\nrev " + strconv.Itoa(rev) + " · " + strconv.Itoa(slots.Size()) + " slot(s) · admin " + admin.String() + "\n\n")
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
		return "# Not found\n\nNo such slot.\n\n[Slot index](" + webPath + ":slots)\n"
	}
	s := v.(*slot)
	body := s.body
	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	return "# " + slug + "\n\n" + strconv.Itoa(len(s.body)) + " bytes · rev " + strconv.Itoa(s.rev) +
		" · written at height " + strconv.FormatInt(s.updated, 10) + "\n\n````\n" + body + "````\n"
}
