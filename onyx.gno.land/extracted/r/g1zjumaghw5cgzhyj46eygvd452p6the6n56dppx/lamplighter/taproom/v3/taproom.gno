// Package taproom is a small realm that needs waking: the brew on tap changes
// on a schedule, and nothing in the realm can make that happen by itself.
//
// Its keeper opens it once, which posts one Lamplighter job. Whoever runs
// that job changes the tap and is paid by the registry.
package taproom

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const (
	// rotateEvery is the number of seconds each brew stays on tap.
	rotateEvery int64 = 300

	// reward is the ugnot the registry pays for each rotation.
	reward int64 = 50000

	// keeper alone can open and close the taproom. It is written here rather
	// than taken from whoever deployed the realm, so that it does not depend
	// on how the package was published or enabled.
	keeper address = "g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx"
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

	// jobID is the taproom's job in the registry, 0 until the keeper opens
	// the taproom. The registry numbers jobs from 1.
	jobID  uint64
	closed bool
)

// Open posts the taproom's job: the first change of brew one interval from
// now, then one every interval. Only the keeper can call it, and only once.
// The keeper's transaction pays the storage deposit for the job.
func Open(cur realm) {
	if cur.Previous().Address() != keeper {
		panic("only the keeper can open the taproom")
	}
	if closed {
		panic("the taproom is closed for good")
	}
	if jobID != 0 {
		panic("the taproom is already open")
	}
	since = time.Now().Unix()
	jobID = registry.Register(cross(cur), "Taproom: change the brew on tap",
		since+rotateEvery, rotateEvery, reward, rotate)
}

// rotate is the callback the registry holds.
//
// The registry runs any callback for anyone, so "the registry called me" is
// not enough: another realm could post a job of its own that points here. The
// job id is what ties a call to the schedule this realm asked for.
func rotate(cur realm, job uint64) error {
	if cur.Previous().PkgPath() != registry.Path() || job != jobID {
		return errors.New("only the taproom's own lamplighter job may change the tap")
	}
	onTap = (onTap + 1) % len(brews)
	rotations++
	since = time.Now().Unix()
	return nil
}

// Close stops the rotation for good and returns the oil the job still holds
// to the keeper. Only the keeper can call it.
func Close(cur realm) {
	if cur.Previous().Address() != keeper {
		panic("only the keeper can close the taproom")
	}
	if closed {
		panic("the taproom is already closed")
	}
	if jobID == 0 {
		panic("the taproom is not open")
	}
	closed = true
	registry.Cancel(cross(cur), jobID, keeper)
}

// OnTap returns the brew currently on tap.
func OnTap() string { return brews[onTap] }

// Rotations returns how many times the tap has been changed.
func Rotations() int64 { return rotations }

// JobID returns the id of this realm's job in the registry, or 0 before the
// taproom opens.
func JobID() uint64 { return jobID }

// Keeper returns the account that can close the taproom.
func Keeper() address { return keeper }

func Render(_ string) string {
	job := strconv.FormatUint(jobID, 10)
	registryURL := strings.TrimPrefix(registry.Path(), "gno.land")
	jobURL := registryURL + ":job/" + job
	now := time.Now().Unix()

	var b strings.Builder
	b.WriteString("# The Taproom\n\n")
	b.WriteString("## On tap: " + OnTap() + "\n\n")
	if jobID != 0 {
		b.WriteString("Poured since " + time.Unix(since, 0).UTC().Format("2006-01-02 15:04:05") +
			" UTC. The tap has been changed " + strconv.FormatInt(rotations, 10) + " times.\n\n")
	}

	switch {
	case jobID == 0:
		b.WriteString("The brew should change every " + strconv.FormatInt(rotateEvery/60, 10) +
			" minutes, but a realm cannot wake itself. The taproom has not opened yet: when its keeper opens it, " +
			"it posts that work as a Lamplighter job, and whoever runs the job changes the tap and is paid for it.\n\n")
	case closed:
		b.WriteString("The taproom is closed: its keeper stopped the rotation.\n\n")
	default:
		b.WriteString("The brew should change every " + strconv.FormatInt(rotateEvery/60, 10) +
			" minutes, but a realm cannot wake itself. So the taproom posted the work as [Lamplighter job " +
			job + "](" + jobURL + "): whoever runs it changes the tap and is paid " +
			strconv.FormatInt(reward, 10) + " ugnot for it.\n\n")

		switch {
		case registry.IsDue(jobID):
			b.WriteString("**The next change is due now.** [Run the job](" + jobURL + ") and it is yours.\n\n")
		case registry.Balance(jobID) < reward:
			b.WriteString("**The job is out of oil**, so nobody will change the tap. [Add oil](" +
				txlink.Realm(registry.Path()).NewLink("Fund").AddArgs("id", job).SetSend("1000000ugnot").URL() + ")\n\n")
		default:
			b.WriteString("Next change in " + strconv.FormatInt(registry.NextDue(jobID)-now, 10) + " seconds.\n\n")
		}
	}

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
