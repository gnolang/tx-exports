package poker

import (
	"bytes"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/cards"
)

// Challenge disputes one element of a shuffle or rekey pass during the
// challenge window (protocol.md section 5).
func Challenge(cur realm, tableID, handNo uint64, accused int, kind string, index int, inB64, inProofHex, outB64, outProofHex string) {
	if !challengesEnabled {
		panic("challenges are disabled on this deployment")
	}
	ctx := newCtx(cur)
	sent := sentUgnot(cur)
	t, h, c := handFor(cur, tableID, handNo)
	if h.Phase != phChallenge {
		panic("not in challenge window")
	}
	if ctx.height > h.Deadline {
		panic("challenge window has passed")
	}
	n := h.n()
	if accused < 0 || accused >= n {
		panic("invalid accused index")
	}
	if accused == c {
		panic("cannot challenge yourself")
	}
	if index < 0 || index >= cards.DeckSize {
		panic("invalid deck index")
	}
	bond := t.ChallengeBond
	challengerSeat := t.Seats[h.Players[c].Seat]
	if sent > 0 {
		if sent != bond {
			panic("attached ugnot must equal the challenge bond")
		}
	} else if challengerSeat.Stack < bond {
		panic("stack too small for the challenge bond")
	}

	in, err := cards.DecodeElement(inB64)
	if err != nil {
		panic("in: " + err.Error())
	}
	out, err := cards.DecodeElement(outB64)
	if err != nil {
		panic("out: " + err.Error())
	}
	inProof, err := cards.DecodeHex(inProofHex, cards.ProofLen)
	if err != nil {
		panic("in proof: " + err.Error())
	}
	outProof, err := cards.DecodeHex(outProofHex, cards.ProofLen)
	if err != nil {
		panic("out proof: " + err.Error())
	}
	seed := seedBytes(h.Players[accused])

	var inRoot, outRoot []byte
	inPos := index
	switch kind {
	case "shuffle":
		if accused == 0 {
			inRoot = cards.CanonRoot()
		} else {
			inRoot = rootAt(h, accused-1)
		}
		outRoot = rootAt(h, accused)
		inPos = cards.Permutation(seed)[index]
	case "rekey":
		inRoot = rootAt(h, n+accused-1)
		outRoot = rootAt(h, n+accused)
	default:
		panic("kind must be shuffle or rekey")
	}
	if !cards.VerifyProof(inRoot, in, inPos, inProof) {
		panic("invalid input proof")
	}
	if !cards.VerifyProof(outRoot, out, index, outProof) {
		panic("invalid output proof")
	}

	e := cards.ShuffleKey(seed)
	var guilty bool
	if kind == "shuffle" {
		guilty = !bytes.Equal(powModP(in, e), out)
	} else {
		k := cards.CardKey(seed, index)
		guilty = !bytes.Equal(powModP(out, e), powModP(in, k))
	}

	rec := ChallengeRecord{Challenger: c, Accused: accused, Kind: kind, Index: index, Guilty: guilty}
	h.Result.Challenges = append(h.Result.Challenges, rec)
	accusedSeat := t.Seats[h.Players[accused].Seat]
	if guilty {
		if sent > 0 {
			ctx.pay(ctx.caller, sent)
		}
		t.abort(ctx, []int{accused}, true)
		return
	}
	if sent == 0 {
		challengerSeat.Stack -= bond
	}
	accusedSeat.Stack += bond
}

func rootAt(h *Hand, pass int) []byte {
	b, err := cards.DecodeHex(h.Roots[pass], 32)
	if err != nil {
		panic("corrupt root")
	}
	return b
}
