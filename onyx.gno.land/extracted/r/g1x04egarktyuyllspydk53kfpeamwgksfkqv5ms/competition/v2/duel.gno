package competition

import (
	"chain/runtime"
	"crypto/ed25519"
	"encoding/hex"
	"strings"
	"time"
)

var duelVerifierKey string

func SetDuelVerifier(cur realm, publicKey string) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	require(validHex(publicKey, 64), "invalid Ed25519 key")
	duelVerifierKey = publicKey
}

const joinWindow int64 = 24*60*60
const runWindow int64 = 24*60*60

type Duel struct {
	ID int64
	Creator address
	Rival address
	Stake int64
	Seed int64
	JoinDeadline int64
	RunDeadline int64
	Joined bool
	CreatorScore *ScoreSubmission
	RivalScore *ScoreSubmission
	SettledAt int64
	Outcome string
	Winner address
	Fee int64
	CreatorCredit int64
	RivalCredit int64
	CreatorClaimed bool
	RivalClaimed bool
}

func CreateDuel(cur realm, rival address, stake int64, reference string) int64 {
	runtime.AssertOriginCall()
	creator := paidCaller(cur, stake)
	require(!paused && duelVerifierKey != "" && firstSeason > 0 && weekID(time.Now().Unix()) >= firstSeason, "duel entries paused or unavailable")
	require(rival.IsValid() && rival != creator, "choose a different pilot")
	require(stake > 0 && stake <= maxCoin/2 && validHex(reference, 32), "invalid stake or reference")
	key := string(creator)+":"+reference
	require(!duelReferences[key], "duel already created")
	id := nextDuelID
	nextDuelID = checkedAdd(id, 1)
	now := time.Now().Unix()
	duels[id] = &Duel{ID: id, Creator: creator, Rival: rival, Stake: stake,
		Seed: seasonSeed(id), JoinDeadline: now+joinWindow}
	duelReferences[key] = true
	pilotDuels[creator] = append(pilotDuels[creator], id)
	pilotDuels[rival] = append(pilotDuels[rival], id)
	return id
}

func JoinDuel(cur realm, id int64) {
	runtime.AssertOriginCall()
	d := mustDuel(id)
	pilot := paidCaller(cur, d.Stake)
	now := time.Now().Unix()
	require(!paused && d.SettledAt == 0 && !d.Joined && now < d.JoinDeadline, "duel closed to deposits")
	require(pilot == d.Rival, "invited rival only")
	d.Joined = true
	d.RunDeadline = now+runWindow
}

func SubmitDuel(cur realm, id, seed int64, version string, score int, digest string, expiry int64, signature string) {
	runtime.AssertOriginCall()
	pilot := paidCaller(cur, 0)
	d := mustDuel(id)
	require(d.Joined && d.SettledAt == 0 && (pilot == d.Creator || pilot == d.Rival), "duel unavailable to this pilot")
	now := time.Now().Unix()
	checkEvidence(now, expiry, d.RunDeadline, d.Seed, seed, version, score, digest)
	message := duelMessage(runtime.ChainID(), cur.PkgPath(), pilot, id, seed, version, score, digest, expiry)
	require(validProof(duelVerifierKey, message, signature), "invalid verifier signature")
	submission := &ScoreSubmission{Seed: seed, Score: score, Digest: digest, Proof: signature, VerifierKey: duelVerifierKey, ExpiresAt: expiry, AcceptedAt: now}
	if pilot == d.Creator {
		require(d.CreatorScore == nil, "creator already submitted")
		d.CreatorScore = submission
	} else {
		require(pilot == d.Rival && d.RivalScore == nil, "rival unavailable or already submitted")
		d.RivalScore = submission
	}
}

func duelMessage(chainID, pkgPath string, pilot address, id, seed int64, version string, score int, digest string, expiry int64) string {
	return strings.Join([]string{"altair-duel-v1", chainID, pkgPath, string(pilot),
		decimal(id), decimal(seed), version, decimal(int64(score)), digest, decimal(expiry)}, "|")
}

func validProof(publicKey, message, signature string) bool {
	if !validHex(publicKey, 64) || !validHex(signature, 128) {
		return false
	}
	key, _ := hex.DecodeString(publicKey)
	proof, _ := hex.DecodeString(signature)
	return ed25519.Verify(key, []byte(message), proof)
}

func SettleDuel(cur realm, id int64) {
	runtime.AssertOriginCall()
	paidCaller(cur, 0)
	now := time.Now().Unix()
	d := mustDuel(id)
	if d.settle(now) && d.Fee > 0 {
		recordRevenue(now, 0, d.Fee)
	}
}

func (d *Duel) settle(now int64) bool {
	if d.SettledAt != 0 {
		return false
	}
	a, b := d.CreatorScore, d.RivalScore
	switch {
	case !d.Joined:
		require(now >= d.JoinDeadline, "rival can still join")
		d.Outcome = "unmatched-refund"
		d.CreatorCredit = d.Stake
	case (a == nil || b == nil) && now < d.RunDeadline:
		panic("pilot can still submit")
	case a == nil && b == nil:
		d.Outcome = "no-show-refund"
		d.CreatorCredit, d.RivalCredit = d.Stake, d.Stake
	case a != nil && b != nil && a.Score == b.Score:
		d.Outcome = "tie-refund"
		d.CreatorCredit, d.RivalCredit = d.Stake, d.Stake
	default:
		pot := checkedAdd(d.Stake, d.Stake)
		d.Fee = pot/10
		d.Outcome = "winner"
		if a == nil || b == nil {
			d.Outcome = "forfeit"
		}
		if a != nil && (b == nil || a.Score > b.Score) {
			d.Winner, d.CreatorCredit = d.Creator, pot-d.Fee
		} else {
			d.Winner, d.RivalCredit = d.Rival, pot-d.Fee
		}
	}
	d.SettledAt = now
	return true
}

func ClaimDuel(cur realm, id int64) int64 {
	runtime.AssertOriginCall()
	pilot := paidCaller(cur, 0)
	d := mustDuel(id)
	amount := d.claim(pilot)
	pay(cur, pilot, amount)
	return amount
}

func (d *Duel) claim(pilot address) int64 {
	require(d.SettledAt > 0, "duel settlement required")
	if pilot == d.Creator {
		if d.CreatorClaimed || d.CreatorCredit == 0 {
			return 0
		}
		d.CreatorClaimed = true
		return d.CreatorCredit
	}
	require(pilot == d.Rival, "participants only")
	if d.RivalClaimed || d.RivalCredit == 0 {
		return 0
	}
	d.RivalClaimed = true
	return d.RivalCredit
}

func mustDuel(id int64) *Duel {
	d := duels[id]
	require(d != nil, "duel not found")
	return d
}
