package tollgate

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestComputeChargeTiers(t *testing.T) {
	c1, err := ComputeCharge(1000, 5)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(5000), c1.GrossUgnot)
	uassert.Equal(t, int64(0), c1.DiscountBps)
	uassert.Equal(t, int64(5000), c1.NetUgnot)

	c2, err := ComputeCharge(1000, 10)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(10000), c2.GrossUgnot)
	uassert.Equal(t, int64(500), c2.DiscountBps)
	uassert.Equal(t, int64(500), c2.Discount)
	uassert.Equal(t, int64(9500), c2.NetUgnot)

	c3, err := ComputeCharge(2000, 50)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(100000), c3.GrossUgnot)
	uassert.Equal(t, int64(1000), c3.DiscountBps)
	uassert.Equal(t, int64(90000), c3.NetUgnot)

	c4, err := ComputeCharge(100, 250)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(1500), c4.DiscountBps)
	uassert.Equal(t, int64(21250), c4.NetUgnot)

	c5, err := ComputeCharge(100, 1000)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(2000), c5.DiscountBps)
	uassert.Equal(t, int64(80000), c5.NetUgnot)

	_, err = ComputeCharge(0, 1)
	uassert.Error(t, err)
	_, err = ComputeCharge(100, 0)
	uassert.Error(t, err)
	_, err = ComputeCharge(maxInt64, 2)
	uassert.Error(t, err)
}

func TestComputeAvailable(t *testing.T) {
	avail, err := ComputeAvailable(10000, 3000, 2000)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(5000), avail)

	_, err = ComputeAvailable(10000, 6000, 5000)
	uassert.Error(t, err)
	_, err = ComputeAvailable(-1, 0, 0)
	uassert.Error(t, err)
}

func TestValidateSlugAndMemo(t *testing.T) {
	uassert.True(t, ValidateSlug("weather-pro"))
	uassert.True(t, ValidateSlug("ai01"))
	uassert.False(t, ValidateSlug("a"))
	uassert.False(t, ValidateSlug("-bad"))
	uassert.False(t, ValidateSlug("bad-"))
	uassert.False(t, ValidateSlug("bad--slug"))
	uassert.False(t, ValidateSlug("BadCase"))

	memo, err := FormatInvoiceMemo(42, "req_2026-11-26.001")
	urequire.NoError(t, err)
	uassert.Equal(t, "tollgate:v1:42:req_2026-11-26.001", memo)

	id, nonce, ok := ParseInvoiceMemo(memo)
	uassert.True(t, ok)
	uassert.Equal(t, uint64(42), id)
	uassert.Equal(t, "req_2026-11-26.001", nonce)

	_, _, ok = ParseInvoiceMemo("tollgate:v1:0:abc")
	uassert.False(t, ok)
	_, _, ok = ParseInvoiceMemo("wrong:v1:1:abc")
	uassert.False(t, ok)
}

func TestReceiptCommitmentCanonical(t *testing.T) {
	resHash := HashResource("GET /v1/weather?city=zurich")
	uassert.True(t, IsValidHexDigest(resHash))

	digest := ReceiptCommitment(
		"onyx-1",
		1,
		7,
		"g1buyer000000000000000000000000000000000",
		"g1prov0000000000000000000000000000000000",
		10,
		9500,
		"inv-0001",
		resHash,
	)
	uassert.True(t, IsValidHexDigest(digest))
	t.Log("GNO_CANONICAL_RES=" + resHash)
	t.Log("GNO_CANONICAL_COMMITMENT=" + digest)
	uassert.True(t, VerifyReceiptCommitment(
		digest,
		"onyx-1", 1, 7,
		"g1buyer000000000000000000000000000000000",
		"g1prov0000000000000000000000000000000000",
		10, 9500, "inv-0001", resHash,
	))

	alt := ReceiptCommitment(
		"onyx-1",
		1,
		7,
		"g1buyer000000000000000000000000000000000|",
		"g1prov0000000000000000000000000000000000",
		10,
		9500,
		"inv-0001",
		resHash,
	)
	uassert.NotEqual(t, digest, alt)
	uassert.False(t, VerifyReceiptCommitment(
		"not-hex",
		"onyx-1", 1, 7, "b", "p", 1, 1, "n", resHash,
	))
}
