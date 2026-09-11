package nslogic

import (
	"strings"

	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
)

/*
THE BLOCK LIST: labels nobody may hold, at any price.

This is NOT the reserved list, and confusing the two would undo both.

	reserved (collections/reserved-labels.json, 232 labels) says
	"blocked from the free tier, buyable at list price like anything
	else". admin*meme being purchasable is deliberate: the harm it
	guards against is handing a phishing address out for nothing, not
	the existence of the name. That list is enforced by the issuer,
	which is the only place that decides what is free.

	THIS list says "not available, full stop". It is the small set where
	the answer does not change when somebody offers money: names that
	impersonate the registry itself, and the registry's own names.

WHY IT LIVES IN THE VAULT'S GLOBALS RATHER THAN IN THIS FILE.

Baking it in would mean a logic deploy to block a word, and the words
worth blocking are exactly the ones discovered after launch — the label
somebody tried yesterday that nobody thought of. Globals are writable by
the admin, survive a logic swap because they belong to the vault, and
cost storage only for what is actually stored.

Chunked because a global value is capped at 512 bytes. Eight chunks is
about four kilobytes, or several hundred labels, which is far more than
this list should ever need — if it grows past that, the thing being
built is a content policy and it belongs off chain where it can be
updated without a transaction.

FAILS OPEN, and that is the uncomfortable choice, so it is written down.
An unreadable chunk blocks nothing rather than blocking everything.
Failing closed here would mean one malformed global takes the whole
registry offline — every registration, for everyone, until an admin
notices. The harm from a blocked label slipping through is one bad name
that an admin can freeze; the harm from failing closed is total. The
list is also not the only defence: the issuer holds the reserved list,
and FreezeName exists for anything that gets past both.
*/

const (
	blockChunks   = 8
	blockKeyStem  = "block"
	blockChunkMax = 512
)

// blockKey is the global name for one chunk: block0 … block7.
func blockKey(i int) string {
	return blockKeyStem + string(rune('0'+i))
}

/*
BlockedLabel reports whether a label may not be registered at all.

Compares against the label as the registry stores it — lowercase, already
validated — so a caller cannot slip past with different casing. Every
comparison is exact: this list holds whole labels, not substrings,
because "contains" matching turns a list of a dozen words into an
unpredictable filter that refuses names nobody meant to refuse.
*/
func BlockedLabel(label string) bool {
	if label == "" {
		return false
	}
	want := strings.ToLower(label)
	for i := 0; i < blockChunks; i++ {
		v := nsdata.GetGlobal(blockKey(i))
		if v == "" {
			continue
		}
		for _, e := range strings.Split(v, ",") {
			if strings.ToLower(strings.TrimSpace(e)) == want {
				return true
			}
		}
	}
	return false
}

// BlockList returns one chunk, so the panel can show and edit what is
// actually stored rather than what somebody believes is stored.
func BlockList(i int) string {
	if i < 0 || i >= blockChunks {
		return ""
	}
	return nsdata.GetGlobal(blockKey(i))
}

// BlockChunks is the number of chunks, so the panel does not hard-code a
// constant that this file might later change.
func BlockChunks() int { return blockChunks }

/*
SetBlockList replaces one chunk. Admin only.

Replaces rather than appends: an append-only list has no way to correct a
mistake, and a mistake here refuses somebody a name for reasons nobody
can see. The panel reads the chunk, edits it, and writes it back whole.
*/
func SetBlockList(cur realm, i int, csv string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if i < 0 || i >= blockChunks {
		panic("nslogic: chunk out of range")
	}
	if len(csv) > blockChunkMax {
		panic("nslogic: that chunk is longer than a global may be")
	}
	// Normalised on the way in, so the comparison above never has to
	// account for whatever spacing somebody typed into a form.
	parts := strings.Split(csv, ",")
	out := []string{}
	for _, p := range parts {
		p = strings.ToLower(strings.TrimSpace(p))
		if p != "" {
			out = append(out, p)
		}
	}
	setGlobal(cur, blockKey(i), strings.Join(out, ","))
}

// assertNotBlocked is the gate both doors pass through — the paid
// registration and the free grant. One function, called twice, because
// a block that only covers one route is not a block.
func assertNotBlocked(label string) {
	if BlockedLabel(label) {
		panic("nslogic: " + label + " is not available")
	}
}
