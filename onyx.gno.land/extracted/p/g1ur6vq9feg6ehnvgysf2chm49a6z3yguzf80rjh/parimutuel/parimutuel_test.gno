package parimutuel

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
)

func TestBasicYesWins(t *testing.T) {
	p := New(100) // 1%
	uassert.NoError(t, p.Place(alice, Yes, 6_000_000))
	uassert.NoError(t, p.Place(bob, Yes, 2_000_000))
	uassert.NoError(t, p.Place(carol, No, 2_000_000))

	uassert.Equal(t, int64(10_000_000), p.Total())
	uassert.Equal(t, int64(8000), p.YesBps())
	uassert.Equal(t, 3, p.Bettors())

	out, err := p.Resolve(Yes)
	uassert.NoError(t, err)
	uassert.Equal(t, int(Yes), int(out))
	uassert.Equal(t, int64(100_000), p.Fee())

	// net pool = 9_900_000, alice has 6/8, bob 2/8
	a, err := p.Claim(alice)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(7_425_000), a)

	b, err := p.Claim(bob)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(2_475_000), b)

	_, err = p.Claim(carol)
	uassert.ErrorIs(t, err, ErrNothingToClaim)

	_, err = p.Claim(alice)
	uassert.ErrorIs(t, err, ErrAlreadyClaimed)
}

func TestEmptyWinningSideVoids(t *testing.T) {
	p := New(100)
	uassert.NoError(t, p.Place(alice, No, 1_000_000))
	out, err := p.Resolve(Yes)
	uassert.NoError(t, err)
	uassert.Equal(t, int(Void), int(out))
	uassert.Equal(t, int64(0), p.Fee())

	amt, err := p.Claim(alice)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(1_000_000), amt)
}

func TestOneSidedPoolNoFee(t *testing.T) {
	p := New(100)
	uassert.NoError(t, p.Place(alice, Yes, 1_000_000))
	uassert.NoError(t, p.Place(bob, Yes, 3_000_000))
	_, err := p.Resolve(Yes)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(0), p.Fee())
	a, _ := p.Claim(alice)
	uassert.Equal(t, int64(1_000_000), a)
}

func TestVoidRefundsBothSides(t *testing.T) {
	p := New(300)
	uassert.NoError(t, p.Place(alice, Yes, 1_000_000))
	uassert.NoError(t, p.Place(alice, No, 500_000))
	_, err := p.Resolve(Void)
	uassert.NoError(t, err)
	a, _ := p.Claim(alice)
	uassert.Equal(t, int64(1_500_000), a)
}

func TestGuards(t *testing.T) {
	p := New(100)
	uassert.ErrorIs(t, p.Place(alice, Void, 1), ErrInvalidSide)
	uassert.ErrorIs(t, p.Place(alice, Yes, 0), ErrInvalidAmount)
	_, err := p.Claim(alice)
	uassert.ErrorIs(t, err, ErrNotResolved)

	uassert.NoError(t, p.Place(alice, Yes, 10))
	_, err = p.Resolve(Pending)
	uassert.ErrorIs(t, err, ErrInvalidOutcome)
	_, err = p.Resolve(Yes)
	uassert.NoError(t, err)
	_, err = p.Resolve(No)
	uassert.ErrorIs(t, err, ErrAlreadyResolved)
	uassert.ErrorIs(t, p.Place(bob, No, 10), ErrAlreadyResolved)
}

func TestFeeClamp(t *testing.T) {
	uassert.Equal(t, MaxFeeBps, New(9999).FeeBps())
	uassert.Equal(t, int64(0), New(-5).FeeBps())
}

func TestMultiplier(t *testing.T) {
	p := New(0)
	uassert.Equal(t, int64(0), p.Multiplier(Yes))
	uassert.NoError(t, p.Place(alice, Yes, 1_000_000))
	uassert.Equal(t, int64(10_000), p.Multiplier(Yes)) // one-sided: refund, 1.00x
	uassert.NoError(t, p.Place(bob, No, 3_000_000))
	uassert.Equal(t, int64(40_000), p.Multiplier(Yes)) // 4.0x
	uassert.Equal(t, int64(13_333), p.Multiplier(No))  // 1.33x
}

func TestLargeNumbersNoOverflow(t *testing.T) {
	p := New(100)
	big := int64(1_000_000_000_000_000) // 1e9 GNOT in ugnot
	uassert.NoError(t, p.Place(alice, Yes, big))
	uassert.NoError(t, p.Place(bob, No, big))
	_, err := p.Resolve(Yes)
	uassert.NoError(t, err)
	a, err := p.Claim(alice)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(1_980_000_000_000_000), a)
}

func TestParseSide(t *testing.T) {
	s, err := ParseSide("YES")
	uassert.NoError(t, err)
	uassert.Equal(t, int(Yes), int(s))
	s, err = ParseSide("no")
	uassert.NoError(t, err)
	uassert.Equal(t, int(No), int(s))
	_, err = ParseSide("maybe")
	uassert.ErrorIs(t, err, ErrInvalidSide)
}
