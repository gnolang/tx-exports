// Package taproom is a small realm that needs waking: the brew on tap changes
// on a schedule, and nothing in the realm can make that happen by itself.
//
// It registers one Lamplighter job when it is deployed. Whoever runs that job
// rotates the tap and is paid by the registry.
package taproom

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry"
)

const (
	registryPath = "gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry"

	// rotateEvery is the number of seconds each brew stays on tap.
	rotateEvery int64 = 300

	// reward is the ugnot the registry pays for each rotation.
	reward int64 = 50000
)

var (
	brews = []string{
		"Gnomish Amber",
		"Deep Root Stout",
		"Mushroom Mead",
		"Lantern Lager",
		"Tinker's Pale",
	}

	onTap     int
	rotations int64
	since     int64
	jobID     uint64
)

func init(cur realm) {
	since = time.Now().Unix()
	jobID = registry.Register(cross(cur), "Taproom: change the brew on tap",
		since+rotateEvery, rotateEvery, reward, rotate)
}

// rotate is the callback the registry holds. It is unexported and gated on
// the registry being the caller, so the schedule is the only way to reach it.
func rotate(cur realm) error {
	if cur.Previous().PkgPath() != registryPath {
		return errors.New("only the lamplighter registry may rotate the tap")
	}
	onTap = (onTap + 1) % len(brews)
	rotations++
	since = time.Now().Unix()
	return nil
}

// OnTap returns the brew currently on tap.
func OnTap() string { return brews[onTap] }

// Rotations returns how many times the tap has been changed.
func Rotations() int64 { return rotations }

// JobID returns the id of this realm's job in the registry.
func JobID() uint64 { return jobID }

func Render(_ string) string {
	job := strconv.FormatUint(jobID, 10)
	registryURL := strings.TrimPrefix(registryPath, "gno.land")

	var b strings.Builder
	b.WriteString("# The Taproom\n\n")
	b.WriteString("## On tap: " + OnTap() + "\n\n")
	b.WriteString("Poured since " + time.Unix(since, 0).UTC().Format(time.RFC3339) +
		". The tap has been changed " + strconv.FormatInt(rotations, 10) + " times.\n\n")
	b.WriteString("The brew changes every " + strconv.FormatInt(rotateEvery/60, 10) +
		" minutes, but this realm cannot wake itself. It posted the work as [Lamplighter job " +
		job + "](" + registryURL + ":job/" + job + "): whoever runs it changes the tap and is paid for it.\n\n")
	b.WriteString("| Brew | |\n|---|---|\n")
	for i, name := range brews {
		mark := ""
		if i == onTap {
			mark = "on tap"
		}
		b.WriteString("| " + name + " | " + mark + " |\n")
	}
	return b.String()
}
