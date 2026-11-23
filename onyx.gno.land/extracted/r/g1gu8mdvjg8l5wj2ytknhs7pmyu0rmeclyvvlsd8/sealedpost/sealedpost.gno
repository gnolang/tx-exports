// Package sealedpost is a time-capsule realm built on commit-reveal.
//
// A capsule stores only a public title and a SHA-256 commitment to a
// secret message (see gno.land/p/g1gu8mdvjg8l5wj2ytknhs7pmyu0rmeclyvvlsd8/commitreveal). The message itself
// stays off-chain and secret until the capsule's unlock height is reached;
// then anyone who knows the message and its salt can reveal it, and the
// realm verifies the reveal against the commitment before publishing the
// text. Knowledge of payload+salt is the authorization to reveal: there is
// deliberately no caller check in Reveal, because the commitment makes a
// forged reveal impossible and lets a recipient (or anyone the author
// trusted with the secret) perform the reveal.
package sealedpost

import (
	"chain/runtime"
	"strconv"

	"gno.land/p/g1gu8mdvjg8l5wj2ytknhs7pmyu0rmeclyvvlsd8/commitreveal"
)

const (
	maxTitleLen   = 80
	maxPayloadLen = 2000
)

// Capsule is one sealed message. IDs are assigned sequentially from 1 and
// the capsule with ID n lives at capsules[n-1].
type Capsule struct {
	ID            uint64
	Author        address
	Recipient     address // zero address = not addressed to anyone; a public "addressed to" label only
	Title         string  // public
	Commitment    string  // commitreveal commitment to the secret payload
	UnlockHeight  int64   // first height at which Reveal is accepted
	CreatedHeight int64
	Revealed      bool
	RevealedText  string // empty until revealed
}

var capsules []*Capsule

// Seal creates a new capsule committing to a secret payload and returns
// the new capsule's ID as a decimal string.
//
// The commitment must be commitreveal.Commit(payload, salt), computed
// off-chain by the author; the payload itself is never sent here.
// unlockHeight must be strictly in the future. recipient is optional:
// empty means "no recipient", otherwise it must be a valid bech32 address
// and is stored as a public label only (it grants no privileges).
func Seal(cur realm, title string, commitment string, unlockHeight int64, recipient string) string {
	author := cur.Previous().Address()

	if len(title) > maxTitleLen {
		panic("sealedpost: title too long (max 80 characters)")
	}
	if !commitreveal.IsCommitment(commitment) {
		panic("sealedpost: invalid commitment: want 64 lowercase hex characters (sha256)")
	}
	now := runtime.ChainHeight()
	if unlockHeight <= now {
		panic("sealedpost: unlock height must be greater than the current height")
	}
	var recip address
	if recipient != "" {
		recip = address(recipient)
		if !recip.IsValid() {
			panic("sealedpost: invalid recipient address")
		}
	}

	c := &Capsule{
		ID:            uint64(len(capsules)) + 1,
		Author:        author,
		Recipient:     recip,
		Title:         title,
		Commitment:    commitment,
		UnlockHeight:  unlockHeight,
		CreatedHeight: now,
	}
	capsules = append(capsules, c)
	return strconv.FormatUint(c.ID, 10)
}

// Reveal publishes the secret payload of capsule id. It is accepted only
// once the current height has reached the capsule's unlock height, and
// only if payload+salt hash to the stored commitment. There is no caller
// restriction: knowing payload+salt is the authorization, and the
// commitment check makes the reveal unforgeable.
func Reveal(_ realm, id uint64, payload string, salt string) string {
	c := capsuleByID(id)
	if c.Revealed {
		panic("sealedpost: capsule already revealed")
	}
	if runtime.ChainHeight() < c.UnlockHeight {
		panic("sealedpost: capsule is still sealed: unlock height not reached")
	}
	if len(payload) > maxPayloadLen {
		panic("sealedpost: payload too long (max 2000 characters)")
	}
	if !commitreveal.Verify(c.Commitment, payload, salt) {
		panic("sealedpost: reveal failed: payload and salt do not match the commitment")
	}
	c.Revealed = true
	c.RevealedText = payload
	return "capsule " + strconv.FormatUint(c.ID, 10) + " revealed"
}

// capsuleByID returns the capsule with the given ID, panicking if there
// is none.
func capsuleByID(id uint64) *Capsule {
	if id == 0 || id > uint64(len(capsules)) {
		panic("sealedpost: capsule not found")
	}
	return capsules[id-1]
}
