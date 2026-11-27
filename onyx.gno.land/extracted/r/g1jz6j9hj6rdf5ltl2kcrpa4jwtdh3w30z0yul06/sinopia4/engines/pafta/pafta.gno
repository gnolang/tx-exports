// Package pafta is the adapter that registers the Pafta engine
// (p/…/sinopia/art/pafta/v1) with core. Core knows the engine only as this
// realm's package path plus an interface value.
//
// Pafta is a collection-level engine: 256 tokens are the 256 sheets of one
// map. Which map and which sheet a token is must stay unknown until the sale
// is over (otherwise buyers could target the summit or the lone island), so
// both come from the collection's final salt (art.Placement):
//
//   - core's own TokenURI / TokenCard / TokenTraits call for a Final Pafta
//     collection is "placed": core passes the collection's final salt in
//     engine.Input.Salt (core-final round), Render and Traits check that the
//     seed is exactly core's (seed == safe.Seed(cid, tid, salt)) and draw
//     sheet tile(tid) of map mapSeed(cid, salt) — no read-back of core;
//   - everything else is "standalone" (art.Render / art.Traits of the seed):
//     core.RenderWith / RenderWithInput / EngineTraits (CollectionID "0",
//     Salt ""), the registration sample and any forged input;
//   - before Final core never calls Render or Traits (placeholder /
//     "Unrevealed"), core.Salt is "" and so are Sheet and Sheets here;
//   - CheckLaunch refuses any supply but 256 (one token per sheet) and
//     GateLaunch (engine.LaunchGate) refuses open mode: an open
//     collection's salt is public from Launch, so a shared map would be
//     targetable. Every Pafta collection is therefore a 256-sheet
//     commit-reveal collection, which is what lets Render trust Input.Salt.
//
// The adapter keeps no state of its own (selfPath is set once by init) and
// has no admin: what it renders is fixed by the p/ package it imports. Never
// mark this realm private (design §5.4: a re-deployable adapter could swap
// the art). Per-chain values (author key, fee) live in config.gno.
package pafta

import (
	"errors"
	"strconv"

	art "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/art/pafta/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/types/v2"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
)

// selfPath is this realm's package path = the engine id in core.
var selfPath string

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// Author is the engine-author key that registers, claims and may deprecate
// this engine in core.
func Author() address { return author }

// SelfPath is the engine id.
func SelfPath() string { return selfPath }

var errSupply = errors.New("pafta: a Pafta collection is exactly " + strconv.Itoa(art.Sheets) +
	" sheets of one map; launch it with maxSupply " + strconv.Itoa(art.Sheets))

// impl is zero-size and declared here, so core runs it with this realm's
// authority (interrealm v2 borrow rule #1).
type impl struct{}

func (impl) Manifest() engine.Manifest {
	m := art.Manifest()
	m.Author = author
	m.FeeBps = AuthorFeeBps
	return m
}

func (impl) ValidateParams(params string) error { return art.ValidateParams(params) }

// TraitTypes: every collection uses the manifest's list.
func (impl) TraitTypes(params string) []string { return art.Manifest().TraitTypes }

// CheckLaunch: one token per sheet, so the supply is exactly 256.
func (impl) CheckLaunch(cid, params string, maxSupply int64) error {
	if maxSupply != art.Sheets {
		return errSupply
	}
	return nil
}

var errOpen = errors.New("pafta: a Pafta map stays hidden until the reveal; launch in reveal mode (open mode publishes the salt)")

// GateLaunch (engine.LaunchGate): reveal mode only.
func (impl) GateLaunch(c engine.Collection) error {
	if c.Mode != engine.ModeReveal {
		return errOpen
	}
	return nil
}

func (impl) Traits(in engine.Input) []engine.Trait {
	if p, ok := placed(in); ok {
		cfg, _ := art.ParseParams(in.Params)
		return art.SheetTraits(in.Seed, cfg, p)
	}
	return art.Traits(in)
}

func (impl) Render(in engine.Input) string {
	if p, ok := placed(in); ok {
		cfg, _ := art.ParseParams(in.Params)
		return art.SheetSVG(in.Seed, cfg, p)
	}
	return art.Render(in)
}

// Media: an svg engine; Render is the art.
func (impl) Media(in engine.Input) engine.Media { return engine.Media{} }

// Register is an explicit call, not init: under the inert package policy
// init runs inside the approver's transaction (RA B-1). It registers this
// realm, once, and core accepts it only when the transaction is signed by
// the manifest author (author, config.gno). salt "" = no commit
// reservation; the fingerprint is in core's in-source reserved table
// (r/core config.gno), so only that key can register this art anywhere.
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{}, "")
}

// --- placement ---------------------------------------------------------------

// placed answers core's real token call for a Final Pafta collection: the
// salt is core's (Input.Salt, set only on token reads of a Final
// collection), the collection id a real one and the seed exactly
// safe.Seed(cid, tid, salt). Studio inputs (CollectionID "0", Salt "")
// and anything inconsistent are standalone.
func placed(in engine.Input) (art.Place, bool) {
	if in.CollectionID == "" || in.CollectionID == "0" || !safe.IsHex32(in.Salt) {
		return art.Place{}, false
	}
	n := tidNum(in.TokenID)
	if n < 1 || n > art.Sheets || in.Seed != safe.Seed(in.CollectionID, in.TokenID, in.Salt) {
		return art.Place{}, false
	}
	return art.Placement(in.CollectionID, n, in.Salt), true
}

// finalSalt is the salt of a Final commit-reveal Pafta collection of 256 and
// the numeric token id when tid is a valid one; ok false otherwise (the
// Sheet/Sheets reads, which have no engine input).
func finalSalt(info types.CollectionInfo, tid string) (string, int64, bool) {
	if info.EngineID != selfPath || info.State != types.StateFinal || info.Mode != types.ModeReveal ||
		info.MaxSupply != art.Sheets || !safe.IsHex32(info.Salt) {
		return "", 0, false
	}
	n := tidNum(tid)
	if n < 1 || n > art.Sheets {
		return "", 0, false
	}
	return info.Salt, n, true
}

// tidNum is the canonical decimal token id, 0 otherwise.
func tidNum(tid string) int64 {
	if tid == "" || len(tid) > 4 || tid[0] == '0' {
		return 0
	}
	var n int64
	for i := 0; i < len(tid); i++ {
		c := tid[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// --- reads for composite views -------------------------------------------------

// Sheet is token tid's place on the map once collection cid is Final:
// {"cid","tid","tile","sheet","col","row"} (tile 0..255 row-major, col and
// row 0..15), or null (not a Final commit-reveal Pafta collection, or no
// such token). Before Final it is always null: nothing about the map exists
// yet.
func Sheet(cid, tid string) string {
	info := core.Info(cid)
	salt, n, ok := finalSalt(info, tid)
	if !ok || n > info.Minted {
		return "null"
	}
	if _, err := core.OwnerOf(info.ID, tid); err != nil {
		return "null"
	}
	t := art.Placement(info.ID, n, salt).Tile
	return `{"cid":"` + info.ID + `","tid":"` + tid + `","tile":` + strconv.Itoa(t) + `,"sheet":"` + art.SheetCode(t) +
		`","col":` + strconv.Itoa(t%art.Side) + `,"row":` + strconv.Itoa(t/art.Side) + `}`
}

// Sheets is the whole layout of a Final collection: {"cid","mapSeed",
// "tiles":[tid of each sheet 0..255, "" where no token was minted]} or null
// (as Sheet). A composite view (gallery, reader) crops each token's
// TokenURI to the map face (art.MapX, MapY, MapSize of a Width x Height
// sheet) and lays the faces edge to edge in this order; burned tokens stay
// listed (check OwnerOf).
func Sheets(cid string) string {
	info := core.Info(cid)
	salt, _, ok := finalSalt(info, "1")
	if !ok {
		return "null"
	}
	tiles := make([]int64, art.Sheets)
	for n := int64(1); n <= info.Minted && n <= art.Sheets; n++ {
		tiles[art.Placement(info.ID, n, salt).Tile] = n
	}
	out := `{"cid":"` + info.ID + `","mapSeed":"` + art.MapSeed(info.ID, salt) + `","tiles":[`
	for t, n := range tiles {
		if t > 0 {
			out += ","
		}
		if n == 0 {
			out += `""`
		} else {
			out += `"` + strconv.FormatInt(n, 10) + `"`
		}
	}
	return out + "]}"
}
