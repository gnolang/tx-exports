package aegis_core

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice  = testutils.TestAddress("alice")
	bob    = testutils.TestAddress("bob")
	hacker = testutils.TestAddress("hacker")
)

func TestNewPolicyErrors(t *testing.T) {
	_, err := NewPolicy("", "", 10, 0)
	uassert.ErrorIs(t, err, ErrNoTargets)
	_, err = NewPolicy(alice.String(), "", 0, 0)
	uassert.ErrorIs(t, err, ErrBadCap)
	_, err = NewPolicy("not-an-address", "", 10, 0)
	uassert.ErrorIs(t, err, ErrBadTarget)
}

func TestValidateSpend(t *testing.T) {
	p, err := NewPolicy(alice.String()+", "+bob.String(), "PlaceBet,Tip", 50, 100)
	uassert.NoError(t, err)

	uassert.NoError(t, ValidateSpend(p, alice, "PlaceBet", 50, 10))
	uassert.ErrorIs(t, ValidateSpend(p, hacker, "PlaceBet", 1, 10), ErrTargetDenied)
	uassert.ErrorIs(t, ValidateSpend(p, alice, "Drain", 1, 10), ErrFnDenied)
	uassert.ErrorIs(t, ValidateSpend(p, alice, "PlaceBet", 51, 10), ErrOverCap)
	uassert.ErrorIs(t, ValidateSpend(p, alice, "PlaceBet", 0, 10), ErrNonPositiveAmt)
	uassert.ErrorIs(t, ValidateSpend(p, alice, "PlaceBet", 1, 101), ErrExpired)
}

func TestWildcardFn(t *testing.T) {
	p, _ := NewPolicy(alice.String(), "", 5, 0)
	uassert.NoError(t, ValidateSpend(p, alice, "anything", 5, 999999))
}

func TestCommitReveal(t *testing.T) {
	c := CommitHash("SGF", "pepper-123")
	uassert.Equal(t, 64, len(c))
	uassert.NoError(t, VerifyReveal(c, "SGF", "pepper-123"))
	uassert.Error(t, VerifyReveal(c, "SGS", "pepper-123"))
	uassert.Error(t, VerifyReveal(c, "SGF", "wrong-salt"))
	uassert.ErrorIs(t, VerifyReveal(c, "SGX", "pepper-123"), ErrBadMoves)
	uassert.ErrorIs(t, VerifyReveal(c, "SGF", "short"), ErrBadSalt)
}

func TestResolveDuel(t *testing.T) {
	// S beats F, F beats G, G beats S -> A wins all 3 rounds
	w, log := ResolveDuel("SFG", "FGS")
	uassert.Equal(t, 1, w)
	uassert.Equal(t, 3, len(log))
	uassert.Equal(t, 100, log[2].HPA)
	uassert.Equal(t, 0, log[2].HPB)

	w, _ = ResolveDuel("FGS", "SFG")
	uassert.Equal(t, 2, w)

	w, log = ResolveDuel("SSS", "SSS")
	uassert.Equal(t, 0, w)
	uassert.Equal(t, 76, log[2].HPA)
}

func TestTrustScore(t *testing.T) {
	uassert.Equal(t, int64(500), TrustScore(TrustRecord{}))
	uassert.Equal(t, int64(525+5), TrustScore(TrustRecord{RankedWins: 1, StakedVolume: 5_000_000}))
	uassert.Equal(t, int64(0), TrustScore(TrustRecord{Forfeits: 10}))
	uassert.Equal(t, int64(1000), TrustScore(TrustRecord{RankedWins: 100}))
}

func TestSplitPool(t *testing.T) {
	w, b, s := SplitPool(1001)
	uassert.Equal(t, int64(1001), w+b+s)
	uassert.Equal(t, int64(30), b)
	uassert.Equal(t, int64(20), s)
	uassert.Equal(t, int64(0), ProRata(1, 1, 0))
	uassert.Equal(t, int64(50), ProRata(10, 100, 20))
}
