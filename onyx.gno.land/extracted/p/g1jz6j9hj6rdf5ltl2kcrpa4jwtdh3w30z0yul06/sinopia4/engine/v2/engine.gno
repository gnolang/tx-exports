// Package engine is the "art as code" contract, version 2 (design §5.2,
// mainnet plan §2.3): what an engine implements, what core hands it, and
// the conformance rules both core and engine authors check against.
//
// v2 adds media engines (uploaded raster/IPFS art that core itself can
// serve as TokenURI), per-collection trait types and a launch gate. Input,
// Trait, SampleInput and SampleSeed are byte-for-byte the v1 definitions,
// so an engine's sample fingerprint does not move when it is re-issued
// against v2.
//
// An engine is registered from its own /r/ adapter realm. Because the
// adapter's methods are declared in that realm, core calling them runs the
// engine with the adapter's authority, never core's (interrealm v2 borrow
// rule #1). Methods receive and return plain values only: an engine never
// gets a reference into core state.
package engine

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
)

// Input is everything an engine may depend on. The first eight fields are
// v1's; Salt and FirstOwner were added in the core-final round
// (2026-11-12). Core fills them only on a token read (TokenURI, TokenCard,
// TokenTraits, …) of a Final collection; RenderWith, RenderWithInput and
// the registration sample leave them "" (so no fingerprint moves).
type Input struct {
	Seed           string // 64-hex final seed (sample seeds in Studio)
	Params         string // collection params, in the engine's own format
	CollectionID   string
	TokenID        string
	MintHeight     int64
	LastMoveHeight int64 // patina: holding time = Height - LastMoveHeight
	Moves          int64 // transfers so far
	Height         int64 // height of the read (fixed by Verify)
	// Salt is the collection's final salt (64 hex; Seed = safe.Seed(cid,
	// tid, Salt)), so a collection-level engine needs no read-back of core.
	Salt string
	// FirstOwner is the address the token was minted to (a sale mint or a
	// creator reserve); it never changes, whoever holds the token now.
	FirstOwner address
}

type Trait struct {
	Type, Value string
}

// Engine kinds (Manifest.Kind).
const (
	// KindSVG: Render is the token's art (an allowlisted SVG).
	KindSVG = "svg"
	// KindMedia: Media is the token's art (a checked raster/SVG file or an
	// ipfs:// CIDv1); Render is the token's "card", an allowlisted SVG that
	// SVG-only clients and gnoweb show.
	KindMedia = "media"
)

type Manifest struct {
	Name, Version, Description, License string
	Author                              address // proven by core.ClaimEngine
	ParamsSchema                        string  // JSON Schema subset; Studio builds its form from it
	// TraitTypes is the engine's default trait list. A collection uses
	// TraitTypes(params), stored by core at CreateCollection when it
	// differs; static engines return this list there.
	TraitTypes  []string
	Living      bool  // Render depends on LastMoveHeight/Moves/Height
	MaxSVGBytes int64 // <= MaxSVGBytes; for a media engine the card's cap
	// FeeBps is the author's fee on every primary and secondary sale of a
	// collection that uses this engine, 0..MaxFeeBps. It is fixed at
	// registration; core snapshots it per collection at Launch, caps it by
	// the platform's engine-fee cap and waives it when the collection's
	// creator is the author.
	FeeBps int64
	// Kind is KindSVG or KindMedia (required).
	Kind string
	// MaxMediaBytes caps Media.Data of a media engine: 1..MaxMediaBytes.
	// 0 for an SVG engine.
	MaxMediaBytes int64
}

// Media is a media engine's art for one token. Exactly one of Data and URI
// is set. Data is the raw file (not base64) as a Go string: strings are
// immutable, so core can check and encode it without copying and without
// the engine being able to change it afterwards.
type Media struct {
	Mime   string // MimePNG | MimeWebP | MimeJPEG | MimeSVG
	Data   string // on-chain bytes, or ""
	URI    string // "ipfs://<CIDv1>" when Data is ""
	Sha256 string // lower-case hex of sha256(file); required with Data, optional with URI
}

// IsZero reports an empty Media (what an SVG engine returns).
func (m Media) IsZero() bool {
	return m.Mime == "" && m.Data == "" && m.URI == "" && m.Sha256 == ""
}

// Engine is implemented by a stateless value declared in the adapter realm.
//
// Contract: deterministic in its arguments; ValidateParams("") must accept
// the engine's defaults; Render returns raw SVG (core does the base64);
// Traits only uses types listed in TraitTypes(params), each at most once.
//
// Where core runs engine code (I-12/I-16): every read; and on a
// state-changing path only in the engine user's own transaction —
// RegisterEngine (Manifest, ValidateParams(""), Render and Traits of the
// sample), CreateCollection (ValidateParams, TraitTypes) and Launch
// (CheckLaunch). Core never hands an engine its cur.
type Engine interface {
	Manifest() Manifest
	ValidateParams(params string) error
	// TraitTypes is the trait list of a collection created with params
	// (already accepted by ValidateParams). Static engines return
	// Manifest().TraitTypes.
	TraitTypes(params string) []string
	// CheckLaunch is the engine's launch gate: an error aborts core.Launch
	// (e.g. an upload collection without a bound store, T14). Everything it
	// needs is passed in; nil for generative engines.
	CheckLaunch(cid, params string, maxSupply int64) error
	Traits(in Input) []Trait
	// Render is the token's art (KindSVG) or its card (KindMedia).
	Render(in Input) string
	// Media is the token's art for KindMedia; Media{} for KindSVG.
	Media(in Input) Media
}

// Limits core enforces on every engine.
const (
	MaxSVGBytes     = 65536
	MaxTraits       = 32
	MaxTraitLen     = 64
	MaxNameLen      = 64
	MaxVersionLen   = 32
	MaxDescLen      = 1024
	MaxLicenseLen   = 64
	MaxParamsSchema = 4096
	MaxFeeBps       = 500 // 5%: hard cap of an engine author's fee

	// Media limits (I-15).
	MaxMediaBytes    = 262144 // on-chain raster per token
	MaxMediaSVGBytes = 16384  // on-chain SVG served as media (AssertSVG cost)
	MaxDim           = 4096   // px per side, decompression-bomb guard
)

// Media types core serves (GIF is refused, uploads D5).
const (
	MimeSVG  = "image/svg+xml"
	MimePNG  = "image/png"
	MimeWebP = "image/webp"
	MimeJPEG = "image/jpeg"
)

// IPFSScheme prefixes Media.URI.
const IPFSScheme = "ipfs://"

// SampleInput is the fixed input of an engine's fingerprint: core renders it
// at registration and stores sha256(svg); anyone can recompute it later.
// Identical to engine/v1's.
func SampleInput() Input {
	return Input{
		Seed:           safe.Sha256Hex(safe.Domain + "|engine-sample|v1"),
		CollectionID:   "0",
		TokenID:        "0",
		MintHeight:     1,
		LastMoveHeight: 1,
		Height:         1,
	}
}

// SampleSeed returns the i-th Studio/conformance sample seed (as v1).
func SampleSeed(i int) string {
	return safe.Sha256Hex(safe.Domain + "|sample|v1|" + strconv.Itoa(i))
}

// ValidateManifest checks sizes, text hygiene, the author address and the
// kind.
func ValidateManifest(m Manifest) error {
	fields := []struct {
		name, value string
		max         int
		required    bool
	}{
		{"name", m.Name, MaxNameLen, true},
		{"version", m.Version, MaxVersionLen, true},
		{"description", m.Description, MaxDescLen, false},
		{"license", m.License, MaxLicenseLen, false},
		{"paramsSchema", m.ParamsSchema, MaxParamsSchema, false},
	}
	for _, f := range fields {
		if f.required && f.value == "" {
			return errors.New("manifest " + f.name + ": must not be empty")
		}
		if err := safe.CheckText(f.value, f.max); err != nil {
			return errors.New("manifest " + f.name + ": " + err.Error())
		}
	}
	if !m.Author.IsValid() {
		return errors.New("manifest author: invalid address")
	}
	if err := ValidateTraitTypes(m.TraitTypes); err != nil {
		return errors.New("manifest: " + err.Error())
	}
	if m.FeeBps < 0 || m.FeeBps > MaxFeeBps {
		return errors.New("manifest feeBps: must be 0.." + strconv.Itoa(MaxFeeBps))
	}
	if m.MaxSVGBytes <= 0 || m.MaxSVGBytes > MaxSVGBytes {
		return errors.New("manifest maxSVGBytes: must be 1.." + strconv.Itoa(MaxSVGBytes))
	}
	switch m.Kind {
	case KindSVG:
		if m.MaxMediaBytes != 0 {
			return errors.New("manifest maxMediaBytes: must be 0 for an svg engine")
		}
	case KindMedia:
		if m.MaxMediaBytes <= 0 || m.MaxMediaBytes > MaxMediaBytes {
			return errors.New("manifest maxMediaBytes: must be 1.." + strconv.Itoa(MaxMediaBytes))
		}
	default:
		return errors.New("manifest kind: must be " + KindSVG + " or " + KindMedia)
	}
	return nil
}

// ValidateTraitTypes checks a trait list: at most MaxTraits non-empty,
// unique names that pass CheckText(MaxTraitLen).
func ValidateTraitTypes(tts []string) error {
	if len(tts) > MaxTraits {
		return errors.New("too many trait types")
	}
	for i, tt := range tts {
		if tt == "" {
			return errors.New("empty trait type")
		}
		if err := safe.CheckText(tt, MaxTraitLen); err != nil {
			return errors.New("trait type: " + err.Error())
		}
		for _, prev := range tts[:i] {
			if prev == tt {
				return errors.New("duplicate trait type " + tt)
			}
		}
	}
	return nil
}

// ValidateTraits checks one Traits() result against the manifest's trait
// list (v1 signature; static engines).
func ValidateTraits(m Manifest, ts []Trait) error {
	return ValidateTraitsFor(m.TraitTypes, ts)
}

// ValidateTraitsFor checks one Traits() result against a collection's
// trait list: known types, each at most once, values CheckText(MaxTraitLen).
func ValidateTraitsFor(tts []string, ts []Trait) error {
	if len(ts) > len(tts) {
		return errors.New("traits: more traits than trait types")
	}
	for i, t := range ts {
		if !contains(tts, t.Type) {
			return errors.New("traits: unknown type: " + t.Type)
		}
		for _, prev := range ts[:i] {
			if prev.Type == t.Type {
				return errors.New("traits: duplicate type " + t.Type)
			}
		}
		if err := safe.CheckText(t.Value, MaxTraitLen); err != nil {
			return errors.New("traits " + t.Type + ": " + err.Error())
		}
	}
	return nil
}

// CheckSVG is the output rule core applies to every render (art of an SVG
// engine, card of a media engine).
func CheckSVG(m Manifest, svg string) error {
	return safe.AssertSVG(svg, int(m.MaxSVGBytes))
}

// CheckMedia is the rule core applies to a media engine's Media before it
// serves it as TokenURI (I-15). Accepted:
//
//   - Data: Mime one of the four media types; SVG <= MaxMediaSVGBytes and
//     AssertSVG; a raster <= min(m.MaxMediaBytes, MaxMediaBytes) whose
//     magic and header dimensions (1..MaxDim) match Mime; Sha256 equal to
//     sha256(Data);
//   - URI: "ipfs://" + a CIDv1 (base32, raw or dag-pb, sha2-256); Mime one
//     of the four types; Sha256 "" or 64 lower-case hex, and for a raw CID
//     equal to the CID's digest.
//
// Everything else — both or neither set, another scheme, CIDv0, an unknown
// mime — is an error.
func CheckMedia(m Manifest, md Media) error {
	if md.Data != "" && md.URI != "" {
		return errors.New("media: data and uri are exclusive")
	}
	if !isMime(md.Mime) {
		return errors.New("media: mime must be one of " + MimePNG + ", " + MimeWebP + ", " + MimeJPEG + ", " + MimeSVG)
	}
	if md.Sha256 != "" && !isLowerHex32(md.Sha256) {
		return errors.New("media: sha256 must be 64 lower-case hex characters")
	}
	if md.Data != "" {
		if md.Sha256 == "" {
			return errors.New("media: sha256 is required with data")
		}
		if md.Mime == MimeSVG {
			if len(md.Data) > MaxMediaSVGBytes {
				return errors.New("media: svg larger than " + strconv.Itoa(MaxMediaSVGBytes) + " bytes")
			}
			if err := safe.AssertSVG(md.Data, MaxMediaSVGBytes); err != nil {
				return err
			}
		} else {
			limit := int64(MaxMediaBytes)
			if m.MaxMediaBytes < limit {
				limit = m.MaxMediaBytes
			}
			if int64(len(md.Data)) > limit {
				return errors.New("media: file larger than " + strconv.FormatInt(limit, 10) + " bytes")
			}
			if err := safe.CheckImage(md.Mime, md.Data); err != nil {
				return err
			}
		}
		if safe.Sha256Hex(md.Data) != md.Sha256 {
			return errors.New("media: sha256 does not match the data")
		}
		return nil
	}
	if md.URI == "" {
		return errors.New("media: neither data nor uri")
	}
	if !strings.HasPrefix(md.URI, IPFSScheme) {
		return errors.New("media: uri must be " + IPFSScheme + "<CIDv1>")
	}
	codec, digest, err := safe.ParseCIDv1(md.URI[len(IPFSScheme):])
	if err != nil {
		return err
	}
	if codec == safe.CodecRaw && md.Sha256 != "" && md.Sha256 != digest {
		return errors.New("media: sha256 does not match the raw CID's digest")
	}
	return nil
}

// Conformance is the self-test engine authors run in their _test.gno
// before registering: manifest, default params and trait types,
// determinism, size, SVG hygiene, traits, media (KindMedia: CheckMedia or
// Media{}; KindSVG: Media{}), and — for non-living engines — independence
// from the living fields.
func Conformance(e Engine, samples int) error {
	m := e.Manifest()
	if err := ValidateManifest(m); err != nil {
		return err
	}
	if err := e.ValidateParams(""); err != nil {
		return errors.New("default params rejected: " + err.Error())
	}
	tts := e.TraitTypes("")
	if err := ValidateTraitTypes(tts); err != nil {
		return errors.New("default trait types: " + err.Error())
	}
	inputs := []Input{SampleInput()}
	for i := 0; i < samples; i++ {
		in := SampleInput()
		in.Seed = SampleSeed(i)
		in.TokenID = strconv.Itoa(i + 1)
		inputs = append(inputs, in)
	}
	for _, in := range inputs {
		svg := e.Render(in)
		if svg != e.Render(in) {
			return errors.New("render is not deterministic for seed " + in.Seed)
		}
		if err := CheckSVG(m, svg); err != nil {
			return errors.New("seed " + in.Seed + ": " + err.Error())
		}
		if err := ValidateTraitsFor(tts, e.Traits(in)); err != nil {
			return errors.New("seed " + in.Seed + ": " + err.Error())
		}
		md := e.Media(in)
		if m.Kind == KindSVG && !md.IsZero() {
			return errors.New("an svg engine returns Media{}")
		}
		if m.Kind == KindMedia && !md.IsZero() {
			if err := CheckMedia(m, md); err != nil {
				return errors.New("seed " + in.Seed + ": " + err.Error())
			}
		}
		if !m.Living {
			moved := in
			moved.Height, moved.Moves, moved.LastMoveHeight = in.Height+1000, in.Moves+3, in.Height+500
			if e.Render(moved) != svg {
				return errors.New("non-living engine depends on Height/Moves/LastMoveHeight")
			}
		}
	}
	return nil
}

func isMime(s string) bool {
	return s == MimePNG || s == MimeWebP || s == MimeJPEG || s == MimeSVG
}

func isLowerHex32(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
