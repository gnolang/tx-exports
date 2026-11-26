package kylix

import (
	"chain/runtime"

	"gno.land/p/nym-kylix000/ring/v0"
)

// Bounds for the on-page ring search. Every cap is constant so Render("")
// stays O(1) in book size even when thousands of offers are open or expired.
//
// What may take part (security review 3, R3-2). Every offer was deliverable
// when it was posted, but its owner can make it dead later by moving the
// asset or revoking the approval. So the search checks each offer again:
//   - a token offer must be funded and approved now (token ledgers only);
//   - an item offer of an official collection (Kylix's own code, written not
//     to panic) that registered an approval check must be owned and
//     approved now;
//   - an item offer of any other collection is never checked here, because
//     that would run third-party code: the home page leaves it out, and an
//     offer page keeps it as unverified, after every verified offer.
//
// Crowding (security reviews 2 and 3). Posting an offer is cheap, so one
// account's offers must not push everyone else's out:
//   - the window counts up to matchScanRawLimit newest offers, of which an
//     owner contributes at most matchPerOwnerSeen (kept or skipped as dead
//     or expired); its further offers are passed over without counting, up
//     to matchScanReadLimit offers read in all;
//   - it keeps at most matchPerOwnerWindow offers of one owner;
//   - each wanted-asset bucket keeps at most matchPerOwnerBucket offers of
//     one owner, verified offers first;
//   - an offer may appear in at most matchPerOfferCands candidate rings, so
//     a handful of overlapping offers cannot use up the candidate budget
//     before distinct rings are found;
//   - only rings that close count as search steps, so offers that almost
//     match cost checks but not steps (security review 4, R4-3).
//
// Offers from many different accounts can still fill the window; on the
// home page they must be ready, so they form real rings that anyone may
// settle, and the settler collects their storage deposits.
const (
	matchScanRawLimit   = 100  // max offers counted for the window
	matchScanReadLimit  = 400  // max offers read from storage for the window
	matchScanLimit      = 50   // max offers kept in the search window
	matchPerOwnerSeen   = 8    // max offers of one owner counted (kept or skipped)
	matchPerOwnerWindow = 4    // max offers of one owner in the window
	matchMaxBucket      = 12   // max offers indexed per wanted asset
	matchPerOwnerBucket = 2    // max offers of one owner per wanted asset
	matchPerOfferCands  = 2    // max candidate rings one offer may appear in
	matchMaxSteps       = 500  // max closing rings tried per search (see findHomeRingsFrom)
	matchMaxChecks      = 8000 // max pairs and triples checked per search
	maxHomeRings        = 6    // max rings displayed on the home page
	maxOfferRings       = 6    // max rings displayed on an offer page
	maxCandidates       = 12   // max candidate rings collected before selection
)

// findHomeRings finds up to maxHomeRings disjoint direct rings of 2 or 3
// offers among the newest unexpired offers, every one of them verified ready
// now. It calls no third-party collection code.
func findHomeRings() [][]*Offer {
	return findHomeRingsFrom(newestUnexpiredOffers(0, true))
}

func findHomeRingsFrom(w *window) [][]*Offer {
	if len(w.offers) < 2 {
		return nil
	}
	window := w.offers
	ix := indexByWant(w)

	seen := map[string]bool{}
	uses := map[uint64]int{} // candidate rings each offer appears in
	var cands [][]*Offer
	steps := 0
	add := func(cand []*Offer) {
		k := ringDedupKey(cand)
		if seen[k] {
			return
		}
		for _, o := range cand {
			if uses[o.ID] >= matchPerOfferCands {
				return
			}
		}
		seen[k] = true
		for _, o := range cand {
			uses[o.ID]++
		}
		cands = append(cands, cand)
	}

	// Every pair and triple tried is checked in full before it counts as a
	// step (security review 4, R4-3): a step is a ring that closes, so
	// offers that almost match cannot use up the budget. The loops are
	// bounded by the window and bucket sizes (at most 50 starts, 12 offers
	// per bucket, 12 per pair: 7,800 checks), and by matchMaxChecks.
	checks := 0
	for _, a := range window {
		if steps >= matchMaxSteps || checks >= matchMaxChecks || len(cands) >= maxCandidates {
			break
		}
		if uses[a.ID] >= matchPerOfferCands || !ix.satisfiable(a) {
			continue
		}
		for _, b := range ix.byWant[assetBucketKey(a.Give)] {
			checks++
			if checks > matchMaxChecks || steps >= matchMaxSteps || len(cands) >= maxCandidates || uses[a.ID] >= matchPerOfferCands {
				break
			}
			if uses[b.ID] >= matchPerOfferCands || !directMatch(a, b) {
				continue
			}
			// 2-offer ring: a -> b -> a
			if directMatch(b, a) {
				steps++
				add(canonicalRing([]*Offer{a, b}))
				continue
			}
			// 3-offer ring: a -> b -> c -> a
			for _, c := range ix.byPair[pairKey(b.Give, a.Want)] {
				checks++
				if checks > matchMaxChecks || steps >= matchMaxSteps || len(cands) >= maxCandidates ||
					uses[a.ID] >= matchPerOfferCands || uses[b.ID] >= matchPerOfferCands {
					break
				}
				if c.ID == a.ID || c.Owner == a.Owner || uses[c.ID] >= matchPerOfferCands {
					continue
				}
				if !directMatch(b, c) || !directMatch(c, a) || duplicateGivenItem(a, b, c) {
					continue
				}
				steps++
				add(canonicalRing([]*Offer{a, b, c}))
			}
		}
	}

	if len(cands) == 0 {
		return nil
	}

	// Prefer 3-offer rings over 2-offer rings, then rings with newer offers.
	// len(cands) <= maxCandidates (12), so insertion sort is tiny and cheap.
	for i := 1; i < len(cands); i++ {
		cur := cands[i]
		j := i - 1
		for j >= 0 && ringBefore(cur, cands[j]) {
			cands[j+1] = cands[j]
			j--
		}
		cands[j+1] = cur
	}

	// Pick a non-overlapping subset so each open offer appears once on Home.
	used := map[uint64]bool{}
	var out [][]*Offer
	for _, r := range cands {
		if len(out) >= maxHomeRings {
			break
		}
		overlap := false
		for _, o := range r {
			if used[o.ID] {
				overlap = true
				break
			}
		}
		if overlap {
			continue
		}
		for _, o := range r {
			used[o.ID] = true
		}
		out = append(out, r)
	}
	return out
}

// findRingsForOffer finds up to maxOfferRings direct rings of 2 or 3 offers
// among the newest unexpired offers that include target. Every returned ring
// starts at target. Third-party items are kept unverified, after verified
// offers; no third-party collection code runs.
func findRingsForOffer(target *Offer) [][]*Offer {
	if target == nil || expired(target, runtime.ChainHeight()) {
		return nil
	}
	w := newestUnexpiredOffers(target.ID, false)
	if len(w.offers) == 0 {
		return nil
	}
	ix := indexByWant(w)

	seen := map[string]bool{}
	var out [][]*Offer
	steps := 0

	for _, b := range ix.byWant[assetBucketKey(target.Give)] {
		steps++
		if steps > matchMaxSteps || len(out) >= maxOfferRings {
			break
		}
		if !directMatch(target, b) {
			continue
		}
		if directMatch(b, target) {
			k := ringDedupKey(canonicalRing([]*Offer{target, b}))
			if !seen[k] {
				seen[k] = true
				out = append(out, []*Offer{target, b})
			}
			continue
		}
		for _, c := range ix.byPair[pairKey(b.Give, target.Want)] {
			steps++
			if steps > matchMaxSteps || len(out) >= maxOfferRings {
				break
			}
			if c.ID == target.ID || c.Owner == target.Owner {
				continue
			}
			if !directMatch(b, c) || !directMatch(c, target) {
				continue
			}
			if duplicateGivenItem(target, b, c) {
				continue
			}
			k := ringDedupKey(canonicalRing([]*Offer{target, b, c}))
			if !seen[k] {
				seen[k] = true
				out = append(out, []*Offer{target, b, c})
			}
		}
	}
	return out
}

// readyNow reports whether o may take part in the on-page search, and
// whether it was verified: see the comment on the bounds above. strict
// (the home page) leaves out what cannot be verified without third-party
// code.
func readyNow(o *Offer, strict bool) (ok, verified bool) {
	if o.Give.Kind == ring.Fungible {
		return undeliverable(o) == "", true
	}
	c := getCollection(o.Give.Key)
	if c == nil {
		return false, false
	}
	if IsOfficial(o.Give.Key) && c.approved != nil {
		return undeliverable(o) == "", true
	}
	return !strict, false
}

// newestUnexpiredOffers builds the search window from the newest offers,
// skipping excludeID (see the comment on the bounds above).
func newestUnexpiredOffers(excludeID uint64, strict bool) *window {
	h := runtime.ChainHeight()
	w := newWindow(strict)
	eachOfferBefore(0, func(o *Offer) bool {
		if w.done() {
			return true
		}
		if o.ID != excludeID {
			w.consider(o, h)
		}
		return false
	})
	return w
}

// window collects the search window.
type window struct {
	strict   bool
	offers   []*Offer
	verified map[uint64]bool
	kept     map[address]int
	seen     map[address]int
	counted  int
	read     int
}

func newWindow(strict bool) *window {
	return &window{
		strict:   strict,
		offers:   make([]*Offer, 0, matchScanLimit),
		verified: map[uint64]bool{},
		kept:     map[address]int{},
		seen:     map[address]int{},
	}
}

// done reports whether the window needs no more offers.
func (w *window) done() bool {
	return len(w.offers) >= matchScanLimit || w.counted >= matchScanRawLimit || w.read >= matchScanReadLimit
}

func (w *window) consider(o *Offer, h int64) {
	if w.done() {
		return
	}
	w.read++
	if w.seen[o.Owner] >= matchPerOwnerSeen {
		return // passed over without counting
	}
	w.seen[o.Owner]++
	w.counted++
	if expired(o, h) || w.kept[o.Owner] >= matchPerOwnerWindow {
		return
	}
	ok, verified := readyNow(o, w.strict)
	if !ok {
		return
	}
	w.kept[o.Owner]++
	w.verified[o.ID] = verified
	w.offers = append(w.offers, o)
}

// index is the search window bucketed for the ring search.
type index struct {
	// byWant: offers by wanted asset. Within a bucket, verified offers come
	// first, then lower minimums (an offer asking for more than anyone gives
	// cannot close a ring, so it must not take a place another could use),
	// then newer offers; at most matchPerOwnerBucket per owner and
	// matchMaxBucket in all.
	byWant map[string][]*Offer
	// byPair: the same, by wanted and given asset together, so the last
	// offer of a 3-offer ring is looked for only among offers that give
	// what the first one wants.
	byPair map[string][]*Offer
	// given: the largest amount given of each asset (1 for an item), so an
	// offer whose minimum nobody in the window meets costs no search steps.
	given map[string]int64
}

func pairKey(want, give ring.Asset) string { return assetBucketKey(want) + ">" + assetBucketKey(give) }

func indexByWant(w *window) *index {
	ix := &index{byWant: map[string][]*Offer{}, byPair: map[string][]*Offer{}, given: map[string]int64{}}
	all := make(map[string][]*Offer, len(w.offers))
	var keys []string
	for _, o := range w.offers {
		k := assetBucketKey(o.Want)
		if _, ok := all[k]; !ok {
			keys = append(keys, k)
		}
		all[k] = append(all[k], o)
		amt := o.Give.Amount
		if o.Give.Kind == ring.Item {
			amt = 1
		}
		if gk := assetBucketKey(o.Give); amt > ix.given[gk] {
			ix.given[gk] = amt
		}
	}
	for _, k := range keys {
		list := all[k]
		// Insertion sort: stable, and the window holds at most 50 offers.
		for i := 1; i < len(list); i++ {
			cur := list[i]
			j := i - 1
			for j >= 0 && bucketBefore(w, cur, list[j]) {
				list[j+1] = list[j]
				j--
			}
			list[j+1] = cur
		}
		perOwner := map[address]int{}
		perPairOwner := map[string]int{}
		for _, o := range list {
			if len(ix.byWant[k]) < matchMaxBucket && perOwner[o.Owner] < matchPerOwnerBucket {
				ix.byWant[k] = append(ix.byWant[k], o)
				perOwner[o.Owner]++
			}
			pk := pairKey(o.Want, o.Give)
			if len(ix.byPair[pk]) < matchMaxBucket && perPairOwner[pk+o.Owner.String()] < matchPerOwnerBucket {
				ix.byPair[pk] = append(ix.byPair[pk], o)
				perPairOwner[pk+o.Owner.String()]++
			}
		}
	}
	return ix
}

// satisfiable reports whether some offer in the window gives what o wants,
// at least o's minimum.
func (ix *index) satisfiable(o *Offer) bool {
	need := o.Want.Amount
	if o.Want.Kind == ring.Item {
		need = 1
	}
	return ix.given[assetBucketKey(o.Want)] >= need
}

func bucketBefore(w *window, a, b *Offer) bool {
	if w.verified[a.ID] != w.verified[b.ID] {
		return w.verified[a.ID]
	}
	return a.Want.Amount < b.Want.Amount
}

func assetBucketKey(a ring.Asset) string {
	return kindDigit(a.Kind) + "|" + a.Key + "|" + a.ID
}

// directMatch reports whether offer a can feed offer b directly (no GnoSwap).
func directMatch(a, b *Offer) bool {
	if a.ID == b.ID || a.Owner == b.Owner {
		return false
	}
	if !a.Give.SameAs(b.Want) {
		return false
	}
	if a.Give.Kind == ring.Fungible && a.Give.Amount < b.Want.Amount {
		return false
	}
	return true
}

func duplicateGivenItem(a, b, c *Offer) bool {
	if a.Give.Kind == ring.Item && (a.Give.SameAs(b.Give) || a.Give.SameAs(c.Give)) {
		return true
	}
	if b.Give.Kind == ring.Item && b.Give.SameAs(c.Give) {
		return true
	}
	return false
}

// canonicalRing rotates offs so the smallest offer ID comes first.
func canonicalRing(offs []*Offer) []*Offer {
	minIdx := 0
	for i := 1; i < len(offs); i++ {
		if offs[i].ID < offs[minIdx].ID {
			minIdx = i
		}
	}
	if minIdx == 0 {
		return offs
	}
	res := make([]*Offer, len(offs))
	for i := range offs {
		res[i] = offs[(minIdx+i)%len(offs)]
	}
	return res
}

func ringDedupKey(offs []*Offer) string {
	ids := make([]uint64, len(offs))
	for i, o := range offs {
		ids[i] = o.ID
	}
	return ring.FormatOfferIDs(ids)
}

func maxRingOfferID(offs []*Offer) uint64 {
	var m uint64
	for _, o := range offs {
		if o.ID > m {
			m = o.ID
		}
	}
	return m
}

func ringBefore(a, b []*Offer) bool {
	if len(a) != len(b) {
		return len(a) > len(b)
	}
	ma, mb := maxRingOfferID(a), maxRingOfferID(b)
	if ma != mb {
		return ma > mb
	}
	return a[0].ID < b[0].ID
}
