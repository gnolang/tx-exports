package nsmarket

import (
	"strconv"
	"strings"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// The house fee, expressed the same way the pricing rules are so there
// is one convention on this project and not two:
//
//	"1000000"  a flat amount in ugnot — 1 GNOT
//	"%3"       three percent of the sale
//	"%2.5"     two and a half percent; one decimal place is honoured
//
// Stored in the vault as a global so it can be changed without
// redeploying anything, read fresh on every sale so a change takes
// effect immediately rather than at the next deploy.
const (
	keyFee     = "marketfee"
	defaultFee = "1000000" // 1 GNOT

	// A flat fee is a percentage in disguise on a cheap name: 1 GNOT on
	// a 0.5 GNOT sale is 200%. Rather than forbid cheap listings or let
	// a seller be charged more than they earn, the fee is capped at half
	// the sale. The listing screen shows the seller the actual number
	// before they sign, which is the part that matters.
	maxFeeBps = int64(5000) // 50%
	bpsDenom  = int64(10000)
)

func FeeSpec() string {
	if v := nsdata.GetGlobal(keyFee); v != "" {
		return v
	}
	return defaultFee
}

// SetFee changes it. Admin only, and validated here rather than trusted,
// because a malformed spec would otherwise be read on every sale and
// silently resolve to zero.
/*
SetFee CANNOT WORK FROM HERE, and saying so is the fix.

nsdata.SetGlobalRecord opens with assertIsTrustedLogic, and this realm is
deliberately outside the trusted set — types.gno says so in capitals, and
the deploy panel actively revokes anything but nslogic. So every call
here passed its own admin check and its own validation and then panicked
inside the vault, for everybody, including the correct admin. A dead
control that reads as live is worse than no control: it fails at signing
time, during the incident that prompted reaching for it.

Granting nsmarket vault trust to fix this would surrender the property
the whole realm is built around. So the setter moved to nslogic, which
already has the grant, and runs the same parseFee validation there.
*/
func SetFee(cur realm, spec string) {
	panic("nsmarket: fees are set with nslogic.SetMarketFee — this realm has no vault privileges and never did")
}

// parseFee returns (flat ugnot, basis points, error). Exactly one of the
// first two is non-zero.
func parseFee(spec string) (int64, int64, string) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return 0, 0, ""
	}
	if !strings.HasPrefix(spec, "%") {
		n, err := strconv.ParseInt(spec, 10, 64)
		if err != nil || n < 0 {
			return 0, 0, "fee must be an amount in ugnot or a percentage like %2.5 — got " + spec
		}
		return n, 0, ""
	}

	// A percentage, carried as basis points so "%2.5" is expressible
	// without floating point anywhere near money.
	body := spec[1:]
	whole, frac := body, ""
	if dot := strings.Index(body, "."); dot >= 0 {
		whole, frac = body[:dot], body[dot+1:]
	}
	if whole == "" {
		whole = "0"
	}
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil || w < 0 {
		return 0, 0, "bad percentage — " + spec
	}
	bps := w * 100
	if frac != "" {
		if len(frac) > 1 {
			return 0, 0, "one decimal place at most — " + spec
		}
		f, err2 := strconv.ParseInt(frac, 10, 64)
		if err2 != nil || f < 0 {
			return 0, 0, "bad percentage — " + spec
		}
		bps += f * 10
	}
	if bps > maxFeeBps {
		return 0, 0, "a fee above 50% is not a marketplace — " + spec
	}
	return 0, bps, ""
}

// FeeFor is what the house takes on a sale at this price, and what the
// seller is left with. Exported so the listing screen can show both
// before anybody signs — a fee somebody discovers afterwards is a fee
// they were not told about.
func FeeFor(price int64) (fee, toSeller int64) {
	if price <= 0 {
		return 0, 0
	}
	flat, bps, err := parseFee(FeeSpec())
	if err != "" {
		return 0, price // an unreadable spec charges nothing; it never overcharges
	}
	if bps > 0 {
		fee = price * bps / bpsDenom
	} else {
		fee = flat
	}
	// The cap, applied last, so it bounds a flat fee and a percentage
	// alike however the spec was written.
	if ceiling := price * maxFeeBps / bpsDenom; fee > ceiling {
		fee = ceiling
	}
	if fee < 0 {
		fee = 0
	}
	return fee, price - fee
}

func assertIsAdmin(cur realm) {
	if cur.Previous().Address() != nsdata.GetAdmin() {
		panic("nsmarket: restricted to project admin")
	}
}
