package space

import (
	"encoding/binary"
	"std"
	"strconv"
	"strings"
	"time"

	"gno.land/p/demo/ufmt"
)

const (
	SectionPlatform  Section = "platform"
	SectionResources Section = "resources"
	SectionSocials   Section = "socials"
)

type (
	// Section defines a type for a Gnome space section.
	// Sections can be used for grouping, for example external links.
	Section string

	// ID defines a type for `uint64` IDs.
	ID uint64

	// Link is a reference to an external link.
	Link struct {
		URL   string
		Title string
	}

	// News is a reference to an external news publication.
	News struct {
		ID        ID
		Title     string
		URL       string
		ImageURL  string
		Tags      []string
		CreatedAt time.Time
	}

	// Tool defines a Gno ecosystem tool.
	Tool struct {
		Name        string
		Description string
		URL         string
		Icon        string
	}
)

var (
	locked               bool
	nextVersionRealmPath string
	lastNewsID           ID

	// Editor accounts.
	// These accounts are allowed to add and remove news, tools and links.
	editors []std.Address

	// Ecosystem tools.
	tools []*Tool
)

// String returns the value of the ID as a string.
func (id ID) String() string {
	return strconv.FormatUint(uint64(id), 10)
}

// Key returns the binary representation of the ID to be used as key for AVL trees.
func (id ID) Key() string {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, uint64(id))
	return string(buf)
}

// String returns a Markdown link.
func (l Link) String() string {
	url := l.URL
	if !strings.HasPrefix(url, "https://") {
		url = newRealmURL(url)
	}
	return ufmt.Sprintf("[%s](%s)", l.Title, url)
}

// String returns a Markdown with tool info.
func (t Tool) String() string {
	var buf strings.Builder

	if t.Icon != "" {
		buf.WriteString(ufmt.Sprintf("[![](%s)](%s)\n", t.Icon, t.URL))
	}

	buf.WriteString(ufmt.Sprintf("**[%s](%s)**: ", t.Name, t.URL))
	buf.WriteString(t.Description + "\n")
	return buf.String()
}

// String returns a Markdown with news info.
func (n News) String() string {
	var (
		buf  strings.Builder
		tags []string
	)

	if n.ImageURL != "" {
		buf.WriteString(ufmt.Sprintf("[![](%s)](%s)\n", n.ImageURL, n.URL))
	}

	buf.WriteString(ufmt.Sprintf("**[%s](%s)**\n\n", n.Title, n.URL))
	buf.WriteString("#" + n.ID.String() + " - ")
	buf.WriteString(n.CreatedAt.UTC().Format("Jan 02, 2006 (MST)"))

	for _, tag := range n.Tags {
		tags = append(tags, ufmt.Sprintf("[%s](%s)", tag, newRealmURL("news/"+tag)))
	}

	buf.WriteString(" - " + strings.Join(tags, ", ") + "\n")
	return buf.String()
}

func newRealmURL(renderPath string) string {
	return strings.TrimPrefix(std.CurrentRealm().PkgPath(), "gno.land") + ":" + renderPath
}

func genNewsID() ID {
	lastNewsID += 1
	return lastNewsID
}

func assertIsEditor(addr std.Address) {
	for _, editor := range editors {
		if editor == addr {
			return
		}
	}

	panic("forbidden")
}

func assertRealmIsNotLocked() {
	if locked {
		panic("realm is locked")
	}
}
