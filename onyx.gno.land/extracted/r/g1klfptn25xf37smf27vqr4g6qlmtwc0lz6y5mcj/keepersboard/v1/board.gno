package keepersboard

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"

	"gno.land/r/g1klfptn25xf37smf27vqr4g6qlmtwc0lz6y5mcj/heirloom/v1"
)

const (
	maxNoteLen = 280
	shownNotes = 20
)

type note struct {
	ID     int
	Author address
	Text   string
	At     time.Time
}

var (
	founder address
	pkgPath string
	lastID  seqid.ID
	notes   avl.Tree
	pinned  int
)

func init(cur realm) {
	pkgPath = cur.PkgPath()
	founder = address(strings.Split(pkgPath, "/")[2])
	if !founder.IsValid() {
		panic("deploy the board under an address: gno.land/r/<address>/...")
	}
}

// Post adds a note of up to 280 characters to the board and returns its id.
// Anyone can post; it counts as a sign of life on Heirloom for the signer.
func Post(cur realm, text string) int {
	author := callerOf(cur)
	text = strings.Join(strings.Fields(text), " ")
	if text == "" || utf8.RuneCountInString(text) > maxNoteLen {
		panic("a note must be 1 to " + strconv.Itoa(maxNoteLen) + " characters")
	}
	n := &note{ID: int(lastID.Next()), Author: author, Text: text, At: time.Now()}
	notes.Set(noteKey(n.ID), n)
	heirloom.Touch(cross(cur))
	return n.ID
}

// Pin shows note id at the top of the board. Only the keeper can call it.
func Pin(cur realm, id int) {
	mustBeKeeper(cur)
	mustGetNote(id)
	pinned = id
	heirloom.Touch(cross(cur))
}

// Remove deletes note id. Only the keeper can call it.
func Remove(cur realm, id int) {
	mustBeKeeper(cur)
	mustGetNote(id)
	notes.Remove(noteKey(id))
	if pinned == id {
		pinned = 0
	}
	heirloom.Touch(cross(cur))
}

// Keeper returns who runs the board now: heirloom.Holder of the founder.
func Keeper() address {
	return heirloom.Holder(founder)
}

func callerOf(cur realm) address {
	if !cur.IsCurrent() {
		panic("unauthorized realm")
	}
	caller := cur.Previous()
	if caller.IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("the board does not accept coins")
	}
	return caller.Address()
}

func mustBeKeeper(cur realm) {
	if callerOf(cur) != Keeper() {
		panic("only the keeper can do this; the keeper is " + Keeper().String())
	}
}

func mustGetNote(id int) *note {
	n, ok := notes.Get(noteKey(id)).(*note)
	if !ok {
		panic("note " + strconv.Itoa(id) + " not found")
	}
	return n
}

func noteKey(id int) string {
	return seqid.ID(id).Binary()
}
