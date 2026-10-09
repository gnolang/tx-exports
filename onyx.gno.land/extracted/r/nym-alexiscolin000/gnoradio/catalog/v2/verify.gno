package catalog

import (
	"chain/runtime"
	"crypto/ed25519"
	"encoding/hex"
	"strconv"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Automatic verification, paid by the artist. The artist puts a proof line in
// a place only they control (their Audius bio, or /.well-known/gnoradio.txt on
// their own website); the GnoRadio robot reads it and, off-chain and for free,
// signs a certificate (Ed25519, ClaimMessage) valid for a short while. The
// artist submits it with Claim from their own wallet; after claimDelay anyone
// can finalize: the profile goes to that wallet and turns Verified, which
// opens tips and paid tickets. The robot key signs nothing else; the admin can
// revoke it, cancel a pending claim and undo a wrong one. Changing or revoking
// the key voids every claim it started that is still pending, so a stolen key
// is undone in one call; there is no daily cap that one person could use up
// for everyone.

const (
	claimDelay = 72 * 3600 // seconds a claim stays public before it counts
	certLife   = 2 * 3600  // longest validity of a robot certificate, seconds
)

type claim struct {
	To    address
	Proof string
	At    int64
	Gen   int // the robot key's generation when the claim was made
}

// ClaimMessage is what the robot signs: the chain, the GnoRadio deployment
// (its data realm, so a staging deployment on the same chain cannot reuse a
// certificate), the profile, the wallet, where the proof was found and until
// when the certificate holds.
func ClaimMessage(artistID int, to address, proof string, expires int64) string {
	return "gnoradio-claim|" + runtime.ChainID() + "|" + dataPath + "|" + text.Itoa(artistID) + "|" + to.String() + "|" + proof + "|" + text.Itoa64(expires)
}

// botKey is the robot's Ed25519 public key (empty: verification paused) and
// gen its generation, bumped by SetBot.
func botKey(t *tx) (key []byte, gen int) {
	key, _ = hex.DecodeString(t.val(cConfig, "bot"))
	return key, text.Atoi(t.val(cConfig, "gen"))
}

func getClaim(t *tx, artistID int) *claim {
	rec, ok := t.get(cClaims, store.Pad(artistID))
	if !ok {
		return nil
	}
	f := store.Fields(rec)
	return &claim{To: address(f[0]), Proof: f[1], At: text.Atoi64(f[2]), Gen: text.Atoi(f[3])}
}

// liveClaim is the pending claim made with the current robot key, if any.
func liveClaim(t *tx, artistID int) *claim {
	c := getClaim(t, artistID)
	if _, gen := botKey(t); c == nil || c.Gen != gen {
		return nil
	}
	return c
}

// SetBot sets the robot's Ed25519 public key, hex ("" disables it). Every
// pending claim started with the previous key is voided: its artist claims
// again with a fresh certificate. Admin only.
func SetBot(cur realm, pubKeyHex string) {
	onlyAdmin(cur)
	key, err := hex.DecodeString(pubKeyHex)
	if err != nil || (len(key) != 0 && len(key) != 32) {
		panic("catalog: the robot key is a 32-byte Ed25519 public key in hex")
	}
	t := rd()
	_, gen := botKey(t)
	t.set(cConfig, "bot", hex.EncodeToString(key))
	t.set(cConfig, "gen", text.Itoa(gen+1))
	save(cur, t)
	emitEvent("BotSet", "key", pubKeyHex)
}

// Claim starts the verification of artistID for the caller with the robot's
// certificate (ClaimMessage signed, hex). It replaces any pending claim for the
// artist and restarts the delay. The artist pays its gas.
func Claim(cur realm, artistID int, proof string, expires int64, sigHex string) {
	caller := userCaller(cur)
	noPayment()
	ts := now()
	t := rd()
	key, gen := botKey(t)
	if len(key) == 0 {
		panic("catalog: verification is paused")
	}
	if expires < ts || expires > ts+certLife {
		panic("catalog: this certificate has expired, check your page again")
	}
	// A plain host, so the host shown next to the ✓ is the one the proof
	// was read from (no user info, port, or "?@other.host" trick).
	if !text.HTTPS(proof, 300) || !validHost(hostOf(proof)) {
		panic("catalog: proof must be an https link on a plain host")
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != 64 || !ed25519.Verify(key, []byte(ClaimMessage(artistID, caller, proof, expires)), sig) {
		panic("catalog: this certificate is not valid for your wallet")
	}
	a := mustArtist(t, artistID)
	mustClaimable(t, a, caller)
	mustRobotVerifiable(a)
	t.set(cClaims, store.Pad(artistID), store.Rec(caller.String(), proof, text.Itoa64(ts), text.Itoa(gen)))
	save(cur, t)
	emitEvent("ClaimProposed", "artist", text.Itoa(artistID), "to", caller.String(), "proof", proof)
}

// FinalizeClaim applies a pending claim once claimDelay has passed. Anyone
// can call it, usually the artist from the app.
func FinalizeClaim(cur realm, artistID int) {
	noPayment()
	t := rd()
	c := getClaim(t, artistID)
	if c == nil {
		panic("catalog: no pending verification for this artist")
	}
	if _, gen := botKey(t); c.Gen != gen {
		panic("catalog: this check was signed by a robot key since replaced, check your page again")
	}
	if now() < c.At+claimDelay {
		panic("catalog: verification completes 72 hours after the check")
	}
	a := mustArtist(t, artistID)
	mustClaimable(t, a, c.To)
	t.del(cClaims, store.Pad(artistID))
	if a.Owner == "" {
		a.Owner = c.To
		t.set(cOwners, c.To.String(), text.Itoa(a.ID))
		t.activity("claim", c.To, "0", text.Itoa(a.ID), "0")
	}
	a.Verified = true
	putArtist(t, a)
	t.set(cProofs, store.Pad(artistID), c.Proof)
	save(cur, t)
	emitEvent("ArtistClaimed", "id", text.Itoa(a.ID), "owner", c.To.String(), "proof", c.Proof)
}

// CancelClaim drops a pending claim (e.g. the proof page was hijacked). Admin only.
func CancelClaim(cur realm, artistID int) {
	onlyAdmin(cur)
	t := rd()
	if _, ok := t.get(cClaims, store.Pad(artistID)); !ok {
		panic("catalog: no pending verification for this artist")
	}
	t.del(cClaims, store.Pad(artistID))
	save(cur, t)
	emitEvent("ClaimCancelled", "artist", text.Itoa(artistID))
}

// ResetOwner undoes a wrong claim on an imported profile (e.g. a hijacked
// proof page found too late): the profile is unclaimed again. Self-registered
// profiles keep their owner. Admin only.
func ResetOwner(cur realm, artistID int) {
	onlyAdmin(cur)
	t := rd()
	a := mustArtist(t, artistID)
	if a.Kind == OriginArtist || a.Owner == "" {
		panic("catalog: only a claimed imported profile can be reset")
	}
	t.del(cOwners, a.Owner.String())
	a.Owner, a.Verified = "", false
	if isRef(a.Kind) && !a.Hidden { // a pointer has no name of its own: the claimant's name and bio go too
		if old := skeleton(a.Name); old != "" {
			if id, ok := t.get(cNames, old); ok && text.Atoi(id) == a.ID {
				t.del(cNames, old)
			}
		}
		a.Name, a.Bio = "", ""
	}
	putArtist(t, a)
	t.del(cProofs, store.Pad(artistID))
	t.del(cClaims, store.Pad(artistID))
	save(cur, t)
	emitEvent("OwnerReset", "artist", text.Itoa(artistID))
}

// mustRobotVerifiable refuses the robot's path for a curated profile: it
// carries a real artist's name and tracks that GnoRadio imported, and no
// domain proves who that artist is (neither the import site's operator nor
// any domain an impersonator buys). The moderator assigns it (AssignArtist).
func mustRobotVerifiable(a *Artist) {
	if a.Kind == OriginCurated || a.Kind == OriginJamendo { // Jamendo has no bio a robot could read
		panic("catalog: an imported profile is verified by the GnoRadio moderator, not with a proof page")
	}
}

// mustClaimable: an unowned profile goes to a wallet without a profile; an
// owned one can only be verified for its own wallet.
func mustClaimable(t *tx, a *Artist, to address) {
	if a.Hidden {
		panic("catalog: this artist is hidden")
	}
	if a.Verified {
		panic("catalog: this artist is already verified")
	}
	if a.Owner != "" {
		if a.Owner != to {
			panic("catalog: this profile belongs to another wallet")
		}
		return
	}
	if !role.Canonical(to) || artistOf(t, to) != 0 {
		panic("catalog: this wallet is invalid or already has an artist profile")
	}
}

// ArtistVerified reports whether an artist proved who they are (tips and
// paid tickets need it).
func ArtistVerified(artistID int) bool { return artistAt(artistID, aVerified) == "1" }

// ClaimState is an artist's pending verification: the wallet it goes to and
// when FinalizeClaim may apply it; pending is false when there is none.
func ClaimState(artistID int) (pending bool, to address, readyAt int64) {
	if c := liveClaim(rd(), artistID); c != nil {
		return true, c.To, c.At + claimDelay
	}
	return false, "", 0
}

// PendingClaim is a verification on its way: the artist, the wallet it goes
// to, the proof link and when FinalizeClaim may apply it.
type PendingClaim struct {
	Artist  int
	To      address
	Proof   string
	ReadyAt int64
}

// PendingClaims lists up to limit (1-100) verifications pending with the
// current robot key, by artist id from offset, and how many claims are
// stored (stale ones included, so offset+limit < total means more). A claim
// stays public for 72 hours before it counts: this is where anyone watches
// them.
func PendingClaims(offset, limit int) (out []PendingClaim, total int) {
	t := rd()
	_, gen := botKey(t)
	keys, recs := store.Rows(data.PageAt(cClaims, max0(offset), store.Limit(limit, 100), false))
	for i, k := range keys {
		if f := store.Fields(recs[i]); text.Atoi(f[3]) == gen {
			out = append(out, PendingClaim{Artist: text.Atoi(k), To: address(f[0]), Proof: f[1], ReadyAt: text.Atoi64(f[2]) + claimDelay})
		}
	}
	return out, data.Size(cClaims)
}

// ProofHost is where a verified artist's proof was found: a host they
// control, not proof of who they are, so show it next to the ✓. It is ""
// when the artist is not verified, or a moderator verified it (Verify,
// AssignArtist).
func ProofHost(artistID int) string {
	t := rd()
	return proofHost(t, artistID, artistField(t, artistID, aVerified))
}

func proofHost(t *tx, artistID int, verified string) string {
	if verified == "" {
		return ""
	}
	if h := hostOf(t.val(cProofs, store.Pad(artistID))); validHost(h) {
		return h
	}
	return "" // a record a later release wrote: show no host rather than a wrong one
}

// ClaimJSON is the verification state of an artist for the app:
// {"verified":b,"proof":"…","pending":b,"to":"…","pendingProof":"…","readyAt":n,"bot":"…"}.
func ClaimJSON(artistID int) string {
	t := rd()
	out := `{"verified":` + strconv.FormatBool(artistField(t, artistID, aVerified) == "1") + `,"proof":"` + t.val(cProofs, store.Pad(artistID)) + `"`
	if c := liveClaim(t, artistID); c != nil {
		out += `,"pending":true,"to":"` + c.To.String() + `","pendingProof":"` + c.Proof + `","readyAt":` + text.Itoa64(c.At+claimDelay)
	} else {
		out += `,"pending":false`
	}
	key, _ := botKey(t)
	return out + `,"bot":` + strconv.FormatBool(len(key) != 0) + `}`
}
