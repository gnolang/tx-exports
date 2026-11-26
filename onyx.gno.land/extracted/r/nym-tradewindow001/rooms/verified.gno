package rooms

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// Verified assets. A registry proves where a token or a collection comes
// from, not that it is worth anything: anyone can register a token called
// USDC, and an issuer keeps power over its ledger. So a room opened with
// Open accepts only verified assets: GNOT and wrapped GNOT from the start,
// then tokens and NFT collections the admin verifies, each with a public
// reason. A room opened with OpenMarket accepts any registered asset; the
// name of that call is what the wallet shows when it is signed.
//
// A verification counts only VerifyDelay after the admin makes it, so a
// stolen admin key cannot slip a worthless token into ordinary rooms before
// anyone notices; it is public from the moment it is made. Removing a
// verification counts at once: an ordinary room holding that asset can no
// longer settle, and everyone can still take their items back.

// VerifyDelay is how long a new verification waits before it counts.
const VerifyDelay = 24 * 60 * 60 // seconds

// maxReason bounds a verification's public reason.
const maxReason = 280

type verification struct {
	reason string
	since  int64 // unix seconds from which it counts
	by     address
}

var verified avl.Tree // asset class -> *verification

// seedVerified verifies GNOT and wrapped GNOT from the start.
func seedVerified() {
	verified.Set("coin:ugnot", &verification{reason: "The native coin of gno.land."})
	verified.Set("token:"+wugnotKey, &verification{reason: "GNOT wrapped one to one by gno.land/r/gnoland/wugnot, a realm with no admin."})
}

// Verify makes a coin denom, a registered GRC20 token or a registered NFT
// collection acceptable in ordinary rooms from VerifyDelay from now. kind
// is coin, token or nft; key is the denom, the registry key or the
// collection key. reason is public: say why this asset is safe to trade.
func Verify(cur realm, kind, key, reason string) {
	assertAdmin(cur)
	key = strings.TrimSpace(key)
	switch kind {
	case KindCoin:
		assertDenom(key)
	case KindToken:
		if grc20reg.Get(key) == nil {
			panic("token is not in the GRC20 registry")
		}
	case KindNFT:
		mustCollection(key)
	default:
		panic("kind must be coin, token or nft")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > maxReason {
		panic("give a reason of 1 to " + strconv.Itoa(maxReason) + " bytes")
	}
	for _, r := range reason {
		if r < 0x20 || r == 0x7f {
			panic("the reason has a control character")
		}
	}
	since := time.Now().Unix() + VerifyDelay
	verified.Set(kind+":"+key, &verification{reason: reason, since: since, by: callerOf(cur)})
	chain.Emit("VerifyProposed",
		"kind", kind,
		"key", key,
		"since", strconv.FormatInt(since, 10),
		"reason", reason,
	)
}

// Unverify removes a verification at once. Ordinary rooms stop accepting
// the asset, and those that hold it can no longer settle; deposits stay
// withdrawable. reason is public.
func Unverify(cur realm, kind, key, reason string) {
	assertAdmin(cur)
	class := kind + ":" + strings.TrimSpace(key)
	if !verified.Has(class) {
		panic("that asset is not verified")
	}
	verified.Remove(class)
	chain.Emit("Unverified", "kind", kind, "key", strings.TrimSpace(key), "reason", strings.TrimSpace(reason))
}

// IsVerified reports whether an asset counts as verified now. denom is a
// coin denom, a registry key, or a collection key (with or without
// "#token id").
func IsVerified(kind, denom string) bool {
	return isVerified(kind, denom, time.Now().Unix())
}

func classOf(kind, denom string) string {
	if kind == KindNFT {
		key, _, _ := strings.Cut(denom, "#")
		return KindNFT + ":" + key
	}
	return kind + ":" + denom
}

func isVerified(kind, denom string, now int64) bool {
	v := verified.Get(classOf(kind, denom))
	return v != nil && now >= v.(*verification).since
}

// assertAccepts refuses an asset an ordinary room does not take.
func (r *room) assertAccepts(kind, denom string) {
	if r.openMarket || isVerified(kind, denom, time.Now().Unix()) {
		return
	}
	panic("this room takes only verified assets, and " + denom + " is not verified: trade it in an open-market room")
}

// assertStillVerified stops an ordinary room from settling when one of its
// assets has lost its verification since it went in.
func (r *room) assertStillVerified() {
	if r.openMarket {
		return
	}
	now := time.Now().Unix()
	for _, list := range [][]asset{r.maker.assets, r.taker.assets, r.want} {
		for _, a := range list {
			if !isVerified(a.kind, a.denom, now) {
				panic(a.denom + " is no longer verified, so this room cannot settle: take your items back")
			}
		}
	}
}

// VerifiedJSON lists verifications, counted or still waiting, with their
// public reasons.
func VerifiedJSON(offset, limit int) string {
	offset, limit = page(offset, limit)
	now := time.Now().Unix()
	items := []string{}
	verified.IterateByOffset(offset, limit, func(class string, v any) bool {
		kind, key, _ := strings.Cut(class, ":")
		ver := v.(*verification)
		items = append(items, jsonObject(
			"kind", jsonString(kind),
			"key", jsonString(key),
			"reason", jsonString(ver.reason),
			"since", jsonInt(ver.since),
			"active", jsonBool(now >= ver.since),
		))
		return false
	})
	return jsonObject(
		"assets", jsonArray(items),
		"more", jsonBool(offset+len(items) < verified.Size()),
		"now", jsonInt(now),
	)
}
