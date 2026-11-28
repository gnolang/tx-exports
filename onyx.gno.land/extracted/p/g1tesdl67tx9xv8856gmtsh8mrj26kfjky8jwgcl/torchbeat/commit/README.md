# gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/commit

A tiny commit-reveal helper. Store a hash now, reveal the value in a later
block. Used by the Torchbeat hub to stop a run's log being copied from the
mempool, and reusable by any realm that needs the same.

## Preimage

```
sha256("torchbeat/v1|" + owner + "|" + roomID + "|" + relicDecimal + "|" + log + "|" + salt)
```

Hex, lowercase. `relicDecimal` is the relic as a base-10 integer. `salt` is 32
lowercase hex characters. `Hash` does not enforce the salt format, so the
calling realm must. The JS client computes the same hash; both sides are tested
against shared vectors.

**Keep every field free of `|`.** The fields are joined with `|` and nothing
else, so the preimage is only unambiguous while no field contains one:
`owner="a|b", roomID="c"` and `owner="a", roomID="b|c"` hash the same. `Hash`
does not check this. The calling realm must validate its inputs before hashing.
The Torchbeat hub does: the owner is the caller's address, the room ID must be a
published room (a package path), the log is digits `0`-`8`, the relic is an
integer and the salt is lowercase hex, so none of them can hold a `|`.

## Usage

```go
package myrealm

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/commit"
)

const maxAge = 600 // blocks

var entries avl.Tree // address string -> commit.Entry

func Commit(cur realm, hash string) {
	caller := cur.Previous().Address()
	entries.Set(caller.String(), commit.Entry{Hash: hash, Height: runtime.ChainHeight()})
}

func Reveal(cur realm, roomID string, relic int, log, salt string) {
	caller := cur.Previous().Address()
	// Validate roomID, log and salt here first: none of them may contain "|".
	var e commit.Entry
	if v := entries.Get(caller.String()); v != nil {
		e = v.(commit.Entry)
	}
	got := commit.Hash(caller.String(), roomID, relic, log, salt)
	if why := commit.CheckReveal(e, runtime.ChainHeight(), maxAge, got); why != "" {
		panic("reveal rejected: " + why)
	}
	entries.Remove(caller.String())
	// accept the value
}
```

`CheckReveal` returns, checked in this order: `none` (nothing committed),
`early` (same block as the commit or earlier), `expired` (more than `maxAge`
blocks after the commit), `mismatch` (hash differs), or `""` when the reveal is
allowed.

## Guarantee and limits

- A new value is protected from mempool copying for the commit-to-reveal
  window: until the reveal lands, only the hash is public, and the salt makes it
  unguessable.
- The owner is part of the preimage, so a copied commit hash is useless to
  anyone else: they cannot reveal it under their own address.
- It does not hide the value after reveal, does not stop a committer choosing
  not to reveal, and does not prove the value is honest. That is the
  consuming realm's job.
- Replay protection and entry cleanup are the caller's job (delete the entry on
  reveal as above).
