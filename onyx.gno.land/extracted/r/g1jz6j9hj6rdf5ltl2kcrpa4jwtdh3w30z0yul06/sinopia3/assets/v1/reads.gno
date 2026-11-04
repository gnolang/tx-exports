package assets

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
)

// Every function in this file is read-only. The artwork set of a store is
// public by design (D8: on-chain and plain IPFS art cannot be hidden); the
// site shows only the set composition before a collection's reveal.

func StoreCount() int64 { return storeCount }

// Info is the typed store header for other realms (a copy).
func Info(storeID string) media.StoreInfo {
	s := mustStore(storeID)
	return media.StoreInfo{
		ID:           s.idStr(),
		Owner:        s.owner,
		Label:        s.label,
		Sealed:       s.sealed,
		SealedHeight: s.sealedHeight,
		Artworks:     s.n,
		Slots:        s.slots,
		OnchainN:     s.onchainN,
		IPFSN:        s.ipfsN,
		OnchainBytes: s.onchainBytes,
		TraitTypes:   append([]string{}, s.traitTypes...),
		Tiers:        append([]string{}, s.tiers...),
	}
}

// Store is the store header as JSON: {id, owner, label, state, createdHeight,
// sealedHeight, artworks, slots, onchainN, ipfsN, onchainBytes, received,
// complete, nextUpload, badge, traitTypes, tiers}. received = on-chain bytes
// stored so far; nextUpload = index of the artwork AppendBytes expects next
// (-1 when every on-chain artwork is complete); badge = media.Badge.
func Store(storeID string) string {
	s := mustStore(storeID)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("id", s.idStr())
	w.StrField("owner", s.owner.String())
	w.StrField("label", s.label)
	if s.sealed {
		w.StrField("state", "sealed")
	} else {
		w.StrField("state", "draft")
	}
	w.IntField("createdHeight", s.createdHeight)
	w.IntField("sealedHeight", s.sealedHeight)
	w.IntField("artworks", s.n)
	w.IntField("slots", s.slots)
	w.IntField("onchainN", s.onchainN)
	w.IntField("ipfsN", s.ipfsN)
	w.IntField("onchainBytes", s.onchainBytes)
	w.IntField("received", s.logLen)
	w.BoolField("complete", s.logLen == s.onchainBytes)
	w.IntField("nextUpload", s.nextUpload())
	w.StrField("badge", media.Badge(s.onchainN, s.ipfsN))
	w.Key("traitTypes")
	w.Raw("[" + strings.Join(s.names[:len(s.traitTypes)], ",") + "]")
	w.Key("tiers")
	w.Raw("[" + strings.Join(s.names[len(s.traitTypes):], ",") + "]")
	w.EndObject()
	return w.String()
}

// nextUpload is the on-chain artwork AppendBytes expects next, -1 when all
// are complete. O(1): bytes arrive in artwork order (chainIdx, chainDone).
func (s *store) nextUpload() int64 {
	if s.chainDone >= s.onchainN {
		return -1
	}
	return getU32(s.chainIdx, int(s.chainDone)*4)
}

// ArtworkAt is the typed artwork record (a copy).
func ArtworkAt(storeID string, idx int64) media.Artwork {
	s := mustStore(storeID)
	return s.artwork(s.assertIdx(idx))
}

// ArtworkMeta is ArtworkAt without SHA256, Digest and CID (left ""): the
// cheap form for trait reads (a CID costs ~1.4M gas to encode in the VM).
func ArtworkMeta(storeID string, idx int64) media.Artwork {
	s := mustStore(storeID)
	return s.artworkMeta(s.assertIdx(idx))
}

func (s *store) assertIdx(idx int64) int64 {
	if idx < 0 || idx >= s.n {
		panic("no artwork " + strconv.FormatInt(idx, 10) + " in store " + s.idStr())
	}
	return idx
}

func (s *store) artwork(idx int64) media.Artwork {
	b, i := s.bucketOf(idx)
	r := decodeRecord(b.raw(i))
	a := s.meta(b, i, idx, &r)
	a.SHA256, a.Digest, a.CID = r.shaHex(), r.digestHex(), r.cid()
	return a
}

func (s *store) artworkMeta(idx int64) media.Artwork {
	b, i := s.bucketOf(idx)
	r := decodeRecord(b.raw(i))
	return s.meta(b, i, idx, &r)
}

func (s *store) meta(b *bucket, i int, idx int64, r *record) media.Artwork {
	a := media.Artwork{
		Index:    idx,
		Kind:     r.kind,
		Mime:     r.mime,
		Size:     r.size,
		Have:     r.have,
		Editions: r.editions,
		SlotEnd:  r.slotEnd,
		Title:    b.title(i),
		Tier:     s.tierName(r.tier),
		Traits:   make([]string, len(s.traitTypes)),
		Complete: r.complete(),
	}
	var js []string
	for k := range s.traitTypes {
		if id := r.traits[k]; id > 0 {
			e := s.dict[id-1]
			a.Traits[k] = e.v
			js = append(js, `{"trait_type":`+s.names[k]+`,"value":`+e.js+`}`)
		}
	}
	a.TraitsJSON = strings.Join(js, ",")
	if r.tier > 0 {
		a.TierJSON = s.names[len(s.traitTypes)+r.tier-1]
	}
	return a
}

// Artworks is one page of records as JSON (limit <= MaxPage = 20):
// [{index, kind, mime, mimeType, size, have, complete, editions, slotStart,
// slotEnd, sha256, digest, cid, title, tier, traits:[{trait_type,value}]}].
// kind is "chain" | "ipfs"; digest is the dag-pb root ("" otherwise); cid is
// "" for on-chain artworks. Built from parts escaped once at write time
// (type names, tiers, trait values) and joined once (UP-M1).
func Artworks(storeID string, offset, limit int64) string {
	s := mustStore(storeID)
	if limit <= 0 || limit > MaxPage {
		limit = MaxPage
	}
	if offset < 0 {
		offset = 0
	}
	parts := make([]string, 0, limit)
	for idx := offset; idx < s.n && idx < offset+limit; idx++ {
		parts = append(parts, s.artworkJSON(idx))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// ArtworkJSON is the JSON object of one artwork (also used by the
// upload engine's reads so both realms emit one shape).
func ArtworkJSON(storeID string, idx int64) string {
	s := mustStore(storeID)
	return s.artworkJSON(s.assertIdx(idx))
}

func (s *store) artworkJSON(idx int64) string {
	b, i := s.bucketOf(idx)
	r := decodeRecord(b.raw(i))
	tier := `""`
	if r.tier > 0 {
		tier = s.names[len(s.traitTypes)+r.tier-1]
	}
	traits := make([]string, 0, len(s.traitTypes))
	for k := range s.traitTypes {
		if id := r.traits[k]; id > 0 {
			traits = append(traits, `{"trait_type":`+s.names[k]+`,"value":`+s.dict[id-1].js+`}`)
		}
	}
	return `{"index":` + itoa(idx) +
		`,"kind":"` + media.KindName(r.kind) + `","mime":"` + media.MimeName(r.mime) + `","mimeType":"` + media.MimeType(r.mime) +
		`","size":` + itoa(r.size) + `,"have":` + itoa(r.have) + `,"complete":` + strconv.FormatBool(r.complete()) +
		`,"editions":` + itoa(r.editions) + `,"slotStart":` + itoa(r.slotEnd-r.editions) + `,"slotEnd":` + itoa(r.slotEnd) +
		`,"sha256":"` + r.shaHex() + `","digest":"` + r.digestHex() + `","cid":"` + r.cid() +
		`","title":` + jsonStr(b.title(i)) + `,"tier":` + tier + `,"traits":[` + strings.Join(traits, ",") + `]}`
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// ArtworkBytes is the raw file of a complete on-chain artwork, "" for an
// incomplete or IPFS one. Only complete files passed sha256 + CheckImage.
func ArtworkBytes(storeID string, idx int64) string {
	s := mustStore(storeID)
	b, i := s.bucketOf(s.assertIdx(idx))
	r := decodeRecord(b.raw(i))
	if r.kind != media.KindChain || !r.complete() {
		return ""
	}
	return s.readLog(r.logOff, r.size)
}

// ArtworkDataURI is "data:<mime>;base64,…" for a complete on-chain artwork,
// "" otherwise. mime is one of the four checked types (ENG-I3: no
// free-form media type ever reaches a data URI).
func ArtworkDataURI(storeID string, idx int64) string {
	s := mustStore(storeID)
	b, i := s.bucketOf(s.assertIdx(idx))
	r := decodeRecord(b.raw(i))
	if r.kind != media.KindChain || !r.complete() {
		return ""
	}
	return "data:" + media.MimeType(r.mime) + ";base64," +
		base64.StdEncoding.EncodeToString([]byte(s.readLog(r.logOff, r.size)))
}

// SlotArtwork maps a slot (0..slots-1) to its artwork index and 1-based
// edition: artwork i covers [slotEnd(i-1), slotEnd(i)). O(log n).
func SlotArtwork(storeID string, slot int64) (idx, edition int64) {
	s := mustStore(storeID)
	if slot < 0 || slot >= s.slots {
		panic("slot " + strconv.FormatInt(slot, 10) + " out of range 0.." + strconv.FormatInt(s.slots-1, 10))
	}
	if s.slots == s.n { // every artwork has one edition
		return slot, 1
	}
	var cached *bucket
	cachedKey := int64(-1)
	end := func(idx int64) int64 {
		if bk := idx / bucketSize; bk != cachedKey {
			cached, _ = s.bucketOf(idx)
			cachedKey = bk
		}
		return getU32(cached.raw(int(idx%bucketSize)), offSlotEnd)
	}
	lo, hi := int64(0), s.n-1
	for lo < hi {
		mid := (lo + hi) / 2
		if end(mid) > slot {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	b, i := s.bucketOf(lo)
	raw := b.raw(i)
	return lo, slot - (getU32(raw, offSlotEnd) - getU32(raw, offEditions)) + 1
}

// Composition is the set composition (design §8, D8 "drop table") as JSON:
// {store, sealed, artworks, slots,
//  tiers:[{name, artworks, slots}] (low -> high), untiered:{artworks, slots},
//  traits:[{trait_type, values:[{value, artworks, slots}], none:{artworks, slots}}]}.
// "slots" counts editions, i.e. the odds of a token: slots/total slots.
// O(tiers + distinct values): the counters are kept by AddArtworks /
// Truncate and the names are escaped once, so the largest store the limits
// allow stays far below the query gas cap (UP-M1).
func Composition(storeID string) string {
	s := mustStore(storeID)
	t := len(s.tiers)
	nt := len(s.traitTypes)
	tiers := make([]string, t)
	for i := 0; i < t; i++ {
		tiers[i] = `{"name":` + s.names[nt+i] + `,` + countPair(s.cnt[i+1], s.cnt[t+2+i]) + `}`
	}
	vals := make([][]string, nt)
	sumA := make([]int64, nt)
	sumS := make([]int64, nt)
	base := s.cntBase()
	for i, e := range s.dict {
		a, sl := s.cnt[base+2*i], s.cnt[base+2*i+1]
		sumA[e.k] += a
		sumS[e.k] += sl
		if a == 0 {
			continue // only used by truncated artworks
		}
		vals[e.k] = append(vals[e.k], `{"value":`+e.js+`,`+countPair(a, sl)+`}`)
	}
	traits := make([]string, nt)
	for k := 0; k < nt; k++ {
		traits[k] = `{"trait_type":` + s.names[k] + `,"values":[` + strings.Join(vals[k], ",") + `],"none":{` +
			countPair(s.n-sumA[k], s.slots-sumS[k]) + `}}`
	}
	return `{"store":"` + s.idStr() + `","sealed":` + strconv.FormatBool(s.sealed) + `,"artworks":` + itoa(s.n) +
		`,"slots":` + itoa(s.slots) + `,"tiers":[` + strings.Join(tiers, ",") + `],"untiered":{` +
		countPair(s.cnt[0], s.cnt[t+1]) + `},"traits":[` + strings.Join(traits, ",") + `]}`
}

// CountsJSON aggregates the real-name trait counts of a set of tokens, given
// each token's artwork index and edition (from SlotArtwork), as the members
// of a JSON object: "Tier":{tier:n}, then each creator trait type
// {value:n} in store order, "Edition":{"e/E":n} (artworks with E > 1) and
// "Storage":{"On-chain"|"IPFS":n}; types and values with no count are left
// out. Names are the JSON escaped once at write time, values in dictionary
// order (review UP-M1: no per-read escaping, integer counters only).
func CountsJSON(storeID string, idx, edition []int64) string {
	s := mustStore(storeID)
	if len(idx) != len(edition) {
		panic("CountsJSON: idx and edition differ in length")
	}
	t := len(s.tiers)
	nt := len(s.traitTypes)
	tierC := make([]int64, t+1)
	valC := make([]int64, len(s.dict))
	var onchain, ipfs int64
	edC := map[string]int64{}
	var edOrder []string
	recs := map[int64]record{}
	for i, x := range idx {
		r, ok := recs[x]
		if !ok {
			b, j := s.bucketOf(s.assertIdx(x))
			r = decodeRecord(b.raw(j))
			recs[x] = r
		}
		tierC[r.tier]++
		for k := 0; k < nt; k++ {
			if id := r.traits[k]; id > 0 {
				valC[id-1]++
			}
		}
		if r.kind == media.KindChain {
			onchain++
		} else {
			ipfs++
		}
		if r.editions > 1 {
			label := itoa(edition[i]) + "/" + itoa(r.editions)
			if _, seen := edC[label]; !seen {
				edOrder = append(edOrder, label)
			}
			edC[label]++
		}
	}
	var members []string
	var tiers []string
	for i := 1; i <= t; i++ {
		if tierC[i] > 0 {
			tiers = append(tiers, s.names[nt+i-1]+`:`+itoa(tierC[i]))
		}
	}
	if len(tiers) > 0 {
		members = append(members, `"Tier":{`+strings.Join(tiers, ",")+`}`)
	}
	vals := make([][]string, nt)
	for i, e := range s.dict {
		if valC[i] > 0 {
			vals[e.k] = append(vals[e.k], e.js+`:`+itoa(valC[i]))
		}
	}
	for k := 0; k < nt; k++ {
		if len(vals[k]) > 0 {
			members = append(members, s.names[k]+`:{`+strings.Join(vals[k], ",")+`}`)
		}
	}
	if len(edOrder) > 0 {
		eds := make([]string, len(edOrder))
		for i, l := range edOrder {
			eds[i] = `"` + l + `":` + itoa(edC[l])
		}
		members = append(members, `"Edition":{`+strings.Join(eds, ",")+`}`)
	}
	var st []string
	if onchain > 0 {
		st = append(st, `"On-chain":`+itoa(onchain))
	}
	if ipfs > 0 {
		st = append(st, `"IPFS":`+itoa(ipfs))
	}
	if len(st) > 0 {
		members = append(members, `"Storage":{`+strings.Join(st, ",")+`}`)
	}
	return strings.Join(members, ",")
}

func countPair(artworks, slots int64) string {
	return `"artworks":` + itoa(artworks) + `,"slots":` + itoa(slots)
}

// TierSlots is the typed tier part of Composition: tier names (low ->
// high), the slots each holds, and the slots of untiered artworks. O(tiers).
func TierSlots(storeID string) (tiers []string, slots []int64, untiered int64) {
	s := mustStore(storeID)
	t := len(s.tiers)
	return append([]string{}, s.tiers...), append([]int64{}, s.cnt[t+2:2*t+2]...), s.cnt[t+1]
}

// Render stays minimal and prints no creator text; uploaded collections
// are browsed in the gallery realm.
func Render(path string) string {
	out := "# Sinopia asset stores\n\n" + strconv.FormatInt(storeCount, 10) +
		" stores. Sealed stores never change; uploaded collections are browsed in the Sinopia gallery.\n"
	if strings.HasPrefix(path, "s/") {
		id := strings.TrimPrefix(path, "s/")
		if n, err := strconv.ParseInt(id, 10, 64); err == nil && n >= 1 && n <= storeCount {
			s := mustStore(strconv.FormatInt(n, 10))
			state := "draft"
			if s.sealed {
				state = "sealed at height " + strconv.FormatInt(s.sealedHeight, 10)
			}
			out += "\n## Store " + s.idStr() + "\n\n- State: " + state +
				"\n- Artworks: " + strconv.FormatInt(s.n, 10) + " (" + strconv.FormatInt(s.onchainN, 10) +
				" on-chain, " + strconv.FormatInt(s.ipfsN, 10) + " IPFS)\n- Slots: " + strconv.FormatInt(s.slots, 10) +
				"\n- On-chain bytes: " + strconv.FormatInt(s.onchainBytes, 10) + "\n- Storage: " +
				media.Badge(s.onchainN, s.ipfsN) + "\n"
		}
	}
	return out
}
