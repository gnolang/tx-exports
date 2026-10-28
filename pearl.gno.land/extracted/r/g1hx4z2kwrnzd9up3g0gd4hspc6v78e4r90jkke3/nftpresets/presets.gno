// Package nftpresets lets a collection creator queue a pre-made set of
// tokenURIs (e.g. a 1000-piece PFP drop the creator already generated
// and shuffled) so that each public mint automatically draws the next
// un-revealed piece, instead of letting whoever calls Mint type in their
// own arbitrary tokenURI.
//
// Why this needs to be a separate realm: nft.gno's Mint takes tokenURI
// as a plain string the caller supplies directly, and nft.gno is already
// deployed and immutable (real collections/tokens live there) — there is
// no way to retrofit "pull the next URI from a queue instead of trusting
// the caller's argument" into it in place. This realm wraps it instead:
// MintNext below still calls the real nft.Mint (same royalty/max-supply/
// publicMint rules apply, unchanged), it just decides the tokenURI
// argument itself rather than letting the caller.
//
// Why URIs are queued one at a time (QueuePresetURI, not a batch/slice
// call): gno.land's vm.MsgCall only carries scalar string args, the same
// reason this project's batch minting loops single-URI Mint calls from
// the frontend instead of sending an array in one transaction.
package nftpresets

import (
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

type presetQueue struct {
	uris      []string
	nextIndex int
}

// queues maps collectionID -> *presetQueue.
var queues = avl.NewTree()

func getQueue(collectionID string) *presetQueue {
	v := queues.Get(collectionID)
	if v == nil {
		return nil
	}
	return v.(*presetQueue)
}

// QueuePresetURI appends one tokenURI to a collection's reveal queue.
// Only the collection's creator may call this (checked via nft.GetCollection,
// the same cross-realm ownership check nftlimits.SetMaxPerWallet uses).
// The moment a collection has at least one queued URI, MintNext becomes
// its only minting path from the frontend's perspective — see
// RemainingPresets/HasQueue below, which the UI checks to decide which
// mint flow to show.
func QueuePresetURI(cur realm, collectionID, uri string) {
	caller := unsafe.OriginCaller()
	c := nft.GetCollection(collectionID) // panics if the collection doesn't exist
	if c.Creator != caller {
		panic("only the collection's creator can queue preset artwork")
	}
	if uri == "" {
		panic("uri must not be empty")
	}

	q := getQueue(collectionID)
	if q == nil {
		q = &presetQueue{}
		queues.Set(collectionID, q)
	}
	q.uris = append(q.uris, uri)
}

// HasQueue reports whether a collection has ever had preset artwork
// queued, even if the queue is since exhausted. The frontend uses this
// (rather than RemainingPresets > 0) to tell "never opted into presets,
// mint normally" apart from "opted in and sold out, don't fall back to
// letting minters type their own URI."
func HasQueue(collectionID string) bool {
	return getQueue(collectionID) != nil
}

// RemainingPresets returns how many un-revealed pieces are left in a
// collection's queue (0 if none was ever queued, or it's exhausted).
func RemainingPresets(collectionID string) int {
	q := getQueue(collectionID)
	if q == nil {
		return 0
	}
	remaining := len(q.uris) - q.nextIndex
	if remaining < 0 {
		return 0
	}
	return remaining
}

// TotalPresets returns how many pieces were ever queued for a
// collection in total (revealed + remaining) — for progress display
// like "412/1000 revealed".
func TotalPresets(collectionID string) int {
	q := getQueue(collectionID)
	if q == nil {
		return 0
	}
	return len(q.uris)
}

// MintNext draws the next un-revealed URI from a collection's preset
// queue and mints it to the caller via the real nft.Mint — same
// royalty/max-supply/creator-vs-publicMint rules as a normal mint
// (nft.Mint re-checks all of that itself against the real signer, this
// call doesn't weaken or bypass any of it), except the caller has no
// say over which tokenURI they receive.
func MintNext(cur realm, collectionID string) string {
	q := getQueue(collectionID)
	if q == nil {
		panic("this collection has no preset artwork queue — mint normally instead")
	}
	if q.nextIndex >= len(q.uris) {
		panic("no preset artwork left to reveal — the queue is exhausted")
	}

	uri := q.uris[q.nextIndex]
	q.nextIndex++

	return nft.Mint(cross(cur), collectionID, uri)
}

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		total := TotalPresets(path)
		if total == 0 {
			return "# collection " + path + "\n\nno preset artwork queue configured.\n"
		}
		revealed := total - RemainingPresets(path)
		return "# collection " + path + "\n\n" + strconv.Itoa(revealed) + "/" + strconv.Itoa(total) + " revealed.\n"
	}

	out := "# Hazen NFT Presets\n\n"
	hasAny := false
	queues.Iterate("", "", func(key string, value any) bool {
		hasAny = true
		q := value.(*presetQueue)
		out += "- collection " + key + ": " + strconv.Itoa(q.nextIndex) + "/" + strconv.Itoa(len(q.uris)) + " revealed\n"
		return false
	})
	if !hasAny {
		out += "No collections have a configured preset queue.\n"
	}
	return out
}
