package million

import (
	"strings"
	"testing"

	"chain"
	"chain/banker"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	deployer = testutils.TestAddress("deployer")
	alice    = testutils.TestAddress("alice")
	bob      = testutils.TestAddress("bob")
)

var realmAddr = chain.PackageAddress("gno.land/r/g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr/million/v0")

// Tests own the admin role through a test address rather than DefaultAdmin.
func init() {
	owner = deployer
}

// fund credits the realm with what the next paint call claims to send, as
// the chain would before running the message, and resets the per-message
// origin-send spending limit that the previous call used up.
func fund(n int64) {
	testing.SetOriginSpend(nil)
	if n > 0 {
		testing.IssueCoins(realmAddr, ugnot(n))
	}
}

func balanceOf(a address) int64 {
	return banker.NewReadonlyBanker().GetCoin(a, Denom)
}

func ugnot(n int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin(Denom, n))
}

// testing.SetRealm only affects the frame that calls it, so it cannot be
// wrapped in a helper: every test sets the caller inline.

func TestInitialState(t *testing.T) {
	uassert.Equal(t, Width, GetWidth())
	uassert.Equal(t, Height, GetHeight())
	uassert.Equal(t, DefaultPrice, Price())
	uassert.Equal(t, MaxBatch, MaxBatchSize())
	uassert.Equal(t, 0, Pixel(0, 0))
	uassert.Equal(t, deployer, Owner())
	uassert.Equal(t, 16, len(strings.Split(Palette(), ",")))
}

func TestPaintOnePixel(cur realm, t *testing.T) {
	adminBefore := balanceOf(owner)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price))
	fund(price)
	Paint(cross(cur), 10, 20, 6)

	uassert.Equal(t, 6, Pixel(10, 20))
	uassert.Equal(t, 1, Painted())
	uassert.Equal(t, price, Revenue())
	uassert.Equal(t, int64(1), Paints())
	// The payment went straight to the admin, nothing stayed in the realm.
	uassert.Equal(t, adminBefore+price, balanceOf(owner))
	uassert.Equal(t, int64(0), balanceOf(realmAddr))

	// Anyone can repaint for the same price; the count does not grow.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnot(price))
	fund(price)
	Paint(cross(cur), 10, 20, 15)
	uassert.Equal(t, 15, Pixel(10, 20))
	uassert.Equal(t, 1, Painted())
	uassert.Equal(t, 2*price, Revenue())
	uassert.Equal(t, adminBefore+2*price, balanceOf(owner))
}

func TestAdminPaintsForFree(cur realm, t *testing.T) {
	adminBefore := balanceOf(owner)
	revenueBefore := Revenue()

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(nil)
	Paint(cross(cur), 400, 400, 8)
	uassert.Equal(t, 8, Pixel(400, 400))

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(nil)
	PaintBatch(cross(cur), "401,400,9;402,400,10")
	uassert.Equal(t, 10, Pixel(402, 400))

	// Free means exactly free: the admin must not attach coins either.
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(ugnot(price))
	uassert.AbortsContains(t, cur, "must send exactly 0ugnot", func() { Paint(cross(cur), 403, 400, 1) })

	uassert.Equal(t, revenueBefore, Revenue())
	uassert.Equal(t, adminBefore, balanceOf(owner))
}

func TestPaintRejectsWrongPayment(cur realm, t *testing.T) {
	before := Painted()

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price-1))
	uassert.AbortsContains(t, cur, "must send exactly", func() { Paint(cross(cur), 0, 0, 1) })

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price+1))
	uassert.AbortsContains(t, cur, "must send exactly", func() { Paint(cross(cur), 0, 0, 1) })

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "must send exactly", func() { Paint(cross(cur), 0, 0, 1) })

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("uatom", price)))
	uassert.AbortsContains(t, cur, "only ugnot is accepted", func() { Paint(cross(cur), 0, 0, 1) })

	uassert.Equal(t, before, Painted())
	uassert.Equal(t, 0, Pixel(0, 0))
}

func TestPaintRejectsInvalidPixels(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price))
	uassert.AbortsContains(t, cur, "out of range", func() { Paint(cross(cur), Width, 0, 1) })
	uassert.AbortsContains(t, cur, "out of range", func() { Paint(cross(cur), 0, Height, 1) })
	uassert.AbortsContains(t, cur, "out of range", func() { Paint(cross(cur), -1, 0, 1) })
	uassert.AbortsContains(t, cur, "color must be", func() { Paint(cross(cur), 0, 0, 0) })
	uassert.AbortsContains(t, cur, "color must be", func() { Paint(cross(cur), 0, 0, 16) })
	uassert.AbortsContains(t, cur, "color must be", func() { Paint(cross(cur), 0, 0, -1) })
}

func TestPaintRejectsCodeRealm(cur realm, t *testing.T) {
	// Regression for the OriginSend bypass: an intermediate realm forwards
	// the call while the envelope claims the coins were sent.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(ugnot(price))
	uassert.AbortsContains(t, cur, "directly by a user", func() { Paint(cross(cur), 1, 1, 1) })
	uassert.Equal(t, 0, Pixel(1, 1))
}

func TestPaintBatch(cur realm, t *testing.T) {
	before := Painted()
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(3 * price))
	fund(3 * price)
	PaintBatch(cross(cur), "100,100,1;101,100,2;102,100,3;")

	uassert.Equal(t, 1, Pixel(100, 100))
	uassert.Equal(t, 2, Pixel(101, 100))
	uassert.Equal(t, 3, Pixel(102, 100))
	uassert.Equal(t, before+3, Painted())

	row := Rows(100, 101)
	uassert.Equal(t, Width, len(row))
	uassert.Equal(t, "123", row[100:103])
}

func TestPaintBatchIsAtomic(cur realm, t *testing.T) {
	// One bad pixel rejects the whole batch before anything is written.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(2*price))
	uassert.AbortsContains(t, cur, "out of range", func() { PaintBatch(cross(cur), "200,200,1;9999,0,1") })
	uassert.Equal(t, 0, Pixel(200, 200))

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price))
	uassert.AbortsContains(t, cur, "must send exactly", func() { PaintBatch(cross(cur), "200,200,1;201,200,1") })
	uassert.Equal(t, 0, Pixel(200, 200))

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(price))
	uassert.AbortsContains(t, cur, "x,y,color", func() { PaintBatch(cross(cur), "garbage") })
	uassert.AbortsContains(t, cur, "x,y,color", func() { PaintBatch(cross(cur), "") })
}

func TestPaintBatchTooLarge(cur realm, t *testing.T) {
	var sb strings.Builder
	for i := 0; i <= MaxBatch; i++ {
		if i > 0 {
			sb.WriteByte(';')
		}
		sb.WriteString("0,")
		sb.WriteString(itoa(i))
		sb.WriteString(",1")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(int64(MaxBatch+1)*price))
	uassert.AbortsContains(t, cur, "too many pixels", func() { PaintBatch(cross(cur), sb.String()) })
}

func TestSetPrice(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "owner only", func() { SetPrice(cross(cur), 1) })

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "price must not be negative", func() { SetPrice(cross(cur), -1) })
	SetPrice(cross(cur), 0)
	uassert.Equal(t, int64(0), Price())

	// Free painting requires sending nothing.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Paint(cross(cur), 300, 300, 4)
	uassert.Equal(t, 4, Pixel(300, 300))
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(1))
	uassert.AbortsContains(t, cur, "must send exactly", func() { Paint(cross(cur), 300, 301, 4) })

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(nil)
	SetPrice(cross(cur), DefaultPrice)
}

func TestWithdraw(cur realm, t *testing.T) {
	testing.IssueCoins(realmAddr, ugnot(1_000))
	ro := banker.NewReadonlyBanker()
	bobBefore := ro.GetCoin(bob, Denom)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "owner only", func() { Withdraw(cross(cur), alice, 1) })

	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "amount must be positive", func() { Withdraw(cross(cur), bob, 0) })
	uassert.AbortsWithMessage(t, cur, "invalid address", func() { Withdraw(cross(cur), address("nope"), 1) })
	Withdraw(cross(cur), bob, 600)

	uassert.Equal(t, bobBefore+600, ro.GetCoin(bob, Denom))
	uassert.Equal(t, int64(400), ro.GetCoin(realmAddr, Denom))
	// Leave the realm empty for the tests that assert on it.
	Withdraw(cross(cur), bob, 400)
}

func TestTransferOwnership(cur realm, t *testing.T) {
	original := owner

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "owner only", func() { TransferOwnership(cross(cur), alice) })

	testing.SetRealm(testing.NewUserRealm(original))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "invalid address", func() { TransferOwnership(cross(cur), address("nope")) })
	TransferOwnership(cross(cur), alice)
	uassert.Equal(t, alice, Owner())

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	TransferOwnership(cross(cur), original)
	uassert.Equal(t, original, Owner())
}

func TestVersionAndDirtyRows(cur realm, t *testing.T) {
	v := Version()
	uassert.Equal(t, "", DirtyRows(v))

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(3 * price))
	fund(3 * price)
	PaintBatch(cross(cur), "0,700,1;1,700,2;0,701,3")

	uassert.Equal(t, v+1, Version())
	uassert.Equal(t, "700,701", DirtyRows(v))
	uassert.Equal(t, "", DirtyRows(Version()))

	// A second call on one of those rows moves only that row forward.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnot(price))
	fund(price)
	Paint(cross(cur), 5, 701, 4)
	uassert.Equal(t, v+2, Version())
	uassert.Equal(t, "701", DirtyRows(v+1))
	uassert.Equal(t, "700,701", DirtyRows(v))

	// A rejected paint changes nothing.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnot(1))
	uassert.AbortsContains(t, cur, "must send exactly", func() { Paint(cross(cur), 5, 702, 4) })
	uassert.Equal(t, v+2, Version())
	uassert.Equal(t, "", DirtyRows(v+2))

	// Negative "since" behaves like zero: painted rows only, never blank ones.
	uassert.Equal(t, DirtyRows(0), DirtyRows(-1))
	uassert.True(t, !strings.Contains(","+DirtyRows(0)+",", ",799,"), "row 799 was never painted")
}

func TestRender(t *testing.T) {
	out := Render("")
	uassert.True(t, strings.Contains(out, "# Million Gno"), "title")
	uassert.True(t, strings.Contains(out, "| Size | 1250 x 800 |"), "size row")
	uassert.True(t, strings.Contains(out, "| Price per pixel | 50000ugnot |"), "price row")
	uassert.True(t, strings.Contains(out, "| Admin | "+owner.String()+" |"), "admin row")
	uassert.True(t, strings.Contains(out, "$help&func=PaintBatch"), "help link")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
