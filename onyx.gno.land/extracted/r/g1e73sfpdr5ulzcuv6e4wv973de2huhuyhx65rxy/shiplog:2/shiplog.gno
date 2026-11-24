// ShipLog — an append-only, on-chain release ledger whose classification is
// computed rather than claimed.
//
// A builder records a shipment by supplying the previous version and the new
// one. The realm parses both (SemVer 2.0.0), derives the bump class itself
// ("major"/"minor"/"patch"), and rejects records that do not hold up:
//
//   - a version that does not strictly increase;
//   - a "from" that is not the last version this project actually shipped —
//     which is what makes the ledger a chain of evidence rather than a bag
//     of independent claims;
//   - an author field at all: the writer is the transaction caller, read from
//     the realm context, never a string the submitter can choose.
//
// The realm is deliberately dependency-free: SemVer lives in semver.gno in
// this same package, so no imported package can be re-published underneath it.
package shiplog

import (
	"strconv"
	"strings"
)

// Release is one recorded shipment.
type Release struct {
	Seq         int
	Project     string
	FromVersion string // "" only for the genesis record of a project
	ToVersion   string
	Bump        string // "major" | "minor" | "patch" | "genesis"
	Note        string
	Author      string
}

// Project is one builder's ledger.
type Project struct {
	Slug     string
	Owner    string
	Releases []Release
}

var (
	projects     []*Project
	projectIndex = map[string]*Project{}
	releaseTotal int
)

const (
	maxSlugLen    = 32
	maxNoteLen    = 280
	maxReleases   = 500
	maxProjects   = 200
	renderPerPage = 50
)

// Register opens an empty ledger for slug, owned by the caller.
func Register(cur realm, slug string) {
	caller := cur.Previous().Address().String()
	if err := checkSlug(slug); err != "" {
		panic(err)
	}
	if _, ok := projectIndex[slug]; ok {
		panic("shiplog: project already registered: " + slug)
	}
	if len(projects) >= maxProjects {
		panic("shiplog: project cap reached")
	}
	p := &Project{Slug: slug, Owner: caller}
	projects = append(projects, p)
	projectIndex[slug] = p
}

// Ship appends a release to slug's ledger.
//
// from is "" for the project's first release. The caller must be the project
// owner; the bump class and the chain-of-evidence check are recomputed here.
func Ship(cur realm, slug, from, to, note string) Release {
	caller := cur.Previous().Address().String()
	p, ok := projectIndex[slug]
	if !ok {
		panic("shiplog: unknown project: " + slug)
	}
	if p.Owner != caller {
		panic("shiplog: caller is not the project owner")
	}
	if len(p.Releases) >= maxReleases {
		panic("shiplog: release cap reached")
	}
	if len(note) > maxNoteLen {
		panic("shiplog: note too long")
	}
	if strings.ContainsAny(note, "\r\n") {
		panic("shiplog: note must be a single line")
	}

	toV, err := parseSemver(to)
	if err != nil {
		panic("shiplog: bad version " + strconv.Quote(to) + ": " + err.Error())
	}

	bump := "genesis"
	if from != "" {
		fromV, ferr := parseSemver(from)
		if ferr != nil {
			panic("shiplog: bad previous version " + strconv.Quote(from) + ": " + ferr.Error())
		}
		bump = svBumpPrefix(fromV, toV)
		if bump == "" {
			panic("shiplog: version must increase: " + from + " -> " + to)
		}
	}

	if n := len(p.Releases); n > 0 {
		last := p.Releases[n-1].ToVersion
		if from != last {
			panic("shiplog: from must equal last shipped version (" + last + ")")
		}
	} else if from != "" {
		panic("shiplog: first release must have an empty from")
	}

	r := Release{
		Seq:         len(p.Releases) + 1,
		Project:     slug,
		FromVersion: from,
		ToVersion:   to,
		Bump:        bump,
		Note:        note,
		Author:      caller,
	}
	p.Releases = append(p.Releases, r)
	releaseTotal++
	return r
}

// Count returns how many releases slug has recorded.
func Count(slug string) int {
	if p, ok := projectIndex[slug]; ok {
		return len(p.Releases)
	}
	return 0
}

// Total returns the number of releases and projects recorded.
func Total() (int, int) { return releaseTotal, len(projects) }

// Latest returns the newest release of slug.
func Latest(slug string) (Release, bool) {
	p, ok := projectIndex[slug]
	if !ok || len(p.Releases) == 0 {
		return Release{}, false
	}
	return p.Releases[len(p.Releases)-1], true
}

// BumpClass returns the derived class of the move from -> to, or "" when to
// is not greater. Pure read: no state is touched, so any client can ask the
// same question the realm would answer on a write.
func BumpClass(from, to string) string {
	if from == "" {
		if _, err := parseSemver(to); err != nil {
			return ""
		}
		return "genesis"
	}
	a, err := parseSemver(from)
	if err != nil {
		return ""
	}
	b, err := parseSemver(to)
	if err != nil {
		return ""
	}
	return svBumpPrefix(a, b)
}

// Valid reports whether s is a SemVer 2.0.0 string.
func Valid(s string) bool {
	_, err := parseSemver(s)
	return err == nil
}

func checkSlug(s string) string {
	if s == "" {
		return "shiplog: empty project slug"
	}
	if len(s) > maxSlugLen {
		return "shiplog: project slug too long"
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if !ok {
			return "shiplog: project slug may only contain a-z 0-9 - _"
		}
	}
	return ""
}

func bumpTag(b string) string {
	switch b {
	case "major":
		return "BREAKING"
	case "minor":
		return "FEATURE"
	case "patch":
		return "FIX"
	case "genesis":
		return "GENESIS"
	}
	return strings.ToUpper(b)
}

func shortAddr(a string) string {
	if len(a) <= 12 {
		return a
	}
	return a[:8] + "…" + a[len(a)-4:]
}

// Render draws the ledger as markdown. path selects a single project when set.
func Render(path string) string {
	var b strings.Builder
	total, nproj := Total()
	b.WriteString("# ShipLog\n\n")
	b.WriteString("An append-only release ledger where **the shipment class is computed, " +
		"not claimed**: the realm derives `major`/`minor`/`patch` from the two " +
		"SemVer 2.0.0 versions it is given, and rejects any record whose `from` " +
		"is not the version this project actually shipped last. The author of " +
		"each row is the calling address, never a self-declared field.\n\n")
	b.WriteString("```\nRegister(cur realm, slug string)\n")
	b.WriteString("Ship(cur realm, slug, from, to, note string) Release\n")
	b.WriteString("Count(slug string) int      Total() (int, int)\n")
	b.WriteString("Latest(slug string) (Release, bool)    BumpClass(from, to string) string\n```\n\n")
	b.WriteString("- projects: **" + strconv.Itoa(nproj) + "**\n")
	b.WriteString("- releases: **" + strconv.Itoa(total) + "**\n")
	b.WriteString("- engine: `semver.gno` in this realm (pure Gno, zero imports beyond stdlib)\n\n")

	if len(projects) == 0 {
		b.WriteString("_No projects registered yet._\n")
		return b.String()
	}

	if path != "" {
		p, ok := projectIndex[path]
		if !ok {
			return b.String() + "\n_Unknown project: " + escapeInline(path) + "_\n"
		}
		writeProject(&b, p)
		return b.String()
	}

	b.WriteString("## Projects\n\n| project | owner | releases | latest |\n|---|---|---|---|\n")
	for _, p := range projects {
		latest := "—"
		if n := len(p.Releases); n > 0 {
			latest = "`" + p.Releases[n-1].ToVersion + "`"
		}
		b.WriteString("| [" + p.Slug + "](" + p.Slug + ") | `" + shortAddr(p.Owner) + "` | " +
			strconv.Itoa(len(p.Releases)) + " | " + latest + " |\n")
	}
	b.WriteString("\n")
	for _, p := range projects {
		writeProject(&b, p)
	}
	return b.String()
}

func writeProject(b *strings.Builder, p *Project) {
	b.WriteString("## " + p.Slug + "\n\n")
	b.WriteString("owner: `" + p.Owner + "`\n\n")
	if len(p.Releases) == 0 {
		b.WriteString("_no releases yet_\n\n")
		return
	}
	b.WriteString("| seq | version | bump | note | author |\n|---|---|---|---|---|\n")
	for _, r := range p.Releases {
		note := r.Note
		if note == "" {
			note = "—"
		}
		b.WriteString("| " + strconv.Itoa(r.Seq) + " | `" + r.ToVersion + "` | " +
			bumpTag(r.Bump) + " | " + note + " | `" + shortAddr(r.Author) + "` |\n")
	}
	b.WriteString("\n")
}

// escapeInline neutralises backticks in caller-supplied path text so a crafted
// path cannot break out of the code span it is rendered into.
func escapeInline(s string) string {
	return strings.ReplaceAll(s, "`", "'")
}
