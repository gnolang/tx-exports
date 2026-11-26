package rooms

import (
	"strings"
	"time"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// Read-only views for clients. Each returns a JSON document as a string so
// a frontend can read it with one vm/qeval query. Amounts are strings
// because int64 does not fit a JavaScript number. Times are unix seconds;
// "now" is the block time the answer was computed at.

const maxPage = 50

// Address returns this realm's address: the spender to approve before
// DepositToken, and the account that holds deposits.
func Address() string {
	return self.String()
}

// RoomJSON returns one room, or null when it does not exist.
func RoomJSON(id uint64) string {
	v := rooms.Get(roomKey(id))
	if v == nil {
		return "null"
	}
	return v.(*room).json(time.Now().Unix())
}

// RoomsOfJSON lists the rooms where addr is maker or taker, newest first.
func RoomsOfJSON(addr string, offset, limit int) string {
	offset, limit = page(offset, limit)
	now := time.Now().Unix()
	items := []string{}
	var ids []uint64
	if v := byParty.Get(strings.TrimSpace(addr)); v != nil {
		ids = v.([]uint64)
	}
	more := false
	for i := len(ids) - 1 - offset; i >= 0; i-- {
		if len(items) == limit {
			more = true
			break
		}
		items = append(items, mustRoom(ids[i]).json(now))
	}
	return jsonObject(
		"rooms", jsonArray(items),
		"more", jsonBool(more),
		"now", jsonInt(now),
	)
}

// LatestJSON lists all rooms, newest first.
func LatestJSON(offset, limit int) string {
	offset, limit = page(offset, limit)
	now := time.Now().Unix()
	items := []string{}
	rooms.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		items = append(items, v.(*room).json(now))
		return false
	})
	return jsonObject(
		"rooms", jsonArray(items),
		"total", jsonUint(lastID),
		"now", jsonInt(now),
	)
}

// StatsJSON returns counters and the settled volume per asset.
func StatsJSON() string {
	vol := []string{}
	volume.Iterate("", "", func(key string, v any) bool {
		kind, denom, _ := strings.Cut(key, ":")
		vol = append(vol, jsonObject(
			"kind", jsonString(kind),
			"denom", jsonString(denom),
			"amount", jsonString(jsonInt(v.(int64))),
		))
		return false
	})
	collected := []string{}
	fees.Iterate("", "", func(key string, v any) bool {
		kind, denom, _ := strings.Cut(key, ":")
		collected = append(collected, jsonObject(
			"kind", jsonString(kind),
			"denom", jsonString(denom),
			"amount", jsonString(jsonInt(v.(int64))),
		))
		return false
	})
	return jsonObject(
		"rooms", jsonUint(lastID),
		"settled", jsonUint(nSettled),
		"cancelled", jsonUint(nCancelled),
		"volume", jsonArray(vol),
		"fees", jsonArray(collected),
		"feeBps", jsonUint(openingFee()),
		"treasury", jsonString(treasury.String()),
		"paused", jsonBool(paused),
		"address", jsonString(self.String()),
		"now", jsonInt(time.Now().Unix()),
	)
}

// TokensJSON lists GRC20 tokens from the registry that rooms accept.
func TokensJSON(offset, limit int) string {
	offset, limit = page(offset, limit)
	items := []string{}
	grc20reg.GetRegistry().IterateByOffset(offset, limit, func(key string, v any) bool {
		items = append(items, tokenJSON(key, v.(*grc20.Token)))
		return false
	})
	return jsonObject("tokens", jsonArray(items))
}

// TokenJSON describes one registered token and, when owner is given, the
// owner's balance and current allowance to this realm.
func TokenJSON(key string, owner string) string {
	tok := grc20reg.Get(key)
	if tok == nil {
		return "null"
	}
	if owner == "" {
		return tokenJSON(key, tok)
	}
	who := address(owner)
	if !who.IsValid() {
		return "null"
	}
	return jsonObject(
		"key", jsonString(key),
		"name", jsonString(tok.GetName()),
		"symbol", jsonString(tok.GetSymbol()),
		"decimals", jsonInt(int64(tok.GetDecimals())),
		"balance", jsonString(jsonInt(tok.BalanceOf(who))),
		"allowance", jsonString(jsonInt(tok.Allowance(who, self))),
	)
}

// BalancesJSON lists the registered GRC20 tokens that owner holds, with the
// balance and the allowance to this realm: a wallet's inventory in one
// query. A page covers limit registry entries (at most 50); read on while
// "more" is true.
func BalancesJSON(owner string, offset, limit int) string {
	offset, limit = page(offset, limit)
	who := address(strings.TrimSpace(owner))
	if !who.IsValid() {
		return "null"
	}
	reg := grc20reg.GetRegistry()
	items := []string{}
	seen := 0
	reg.IterateByOffset(offset, limit, func(key string, v any) bool {
		seen++
		tok := v.(*grc20.Token)
		if bal := tok.BalanceOf(who); bal > 0 {
			items = append(items, jsonObject(
				"key", jsonString(key),
				"name", jsonString(tok.GetName()),
				"symbol", jsonString(tok.GetSymbol()),
				"decimals", jsonInt(int64(tok.GetDecimals())),
				"balance", jsonString(jsonInt(bal)),
				"allowance", jsonString(jsonInt(tok.Allowance(who, self))),
			))
		}
		return false
	})
	return jsonObject(
		"tokens", jsonArray(items),
		"more", jsonBool(offset+seen < reg.Size()),
	)
}

// CollectionsJSON lists the GRC721 collections registered with rooms.
func CollectionsJSON(offset, limit int) string {
	offset, limit = page(offset, limit)
	items := []string{}
	collections.IterateByOffset(offset, limit, func(key string, v any) bool {
		col := v.(*collection)
		items = append(items, jsonObject(
			"key", jsonString(key),
			"name", jsonString(col.token.GetName()),
			"symbol", jsonString(col.token.GetSymbol()),
			"listed", jsonBool(col.list != nil),
			"verified", jsonBool(IsVerified(KindNFT, key)),
		))
		return false
	})
	return jsonObject(
		"collections", jsonArray(items),
		"more", jsonBool(offset+len(items) < collections.Size()),
	)
}

// NFTJSON describes one NFT of a registered collection: who owns it, and
// whether this realm is approved to move it. null when the collection is
// not registered or the token does not exist.
func NFTJSON(collectionKey string, tokenID string) string {
	v := collections.Get(collectionKey)
	if v == nil {
		return "null"
	}
	col := v.(*collection)
	tid := grc721.TokenID(tokenID)
	owner, err := col.token.OwnerOf(tid)
	if err != nil {
		return "null"
	}
	approved := col.token.IsApprovedForAll(owner, self)
	if to, err := col.token.GetApproved(tid); err == nil && to == self {
		approved = true
	}
	return jsonObject(
		"key", jsonString(collectionKey),
		"name", jsonString(col.token.GetName()),
		"symbol", jsonString(col.token.GetSymbol()),
		"tokenId", jsonString(tokenID),
		"owner", jsonString(owner.String()),
		"approved", jsonBool(approved),
	)
}

// maxOwnedPerCollection bounds one OwnedJSON page.
const maxOwnedPerCollection = 20

// OwnedJSON lists the NFTs owner holds in registered collections that can
// be listed (those registered with their enumerable view), at most 20 per
// collection, and whether this realm is approved for each. A page covers
// limit collections; read on while "more" is true.
func OwnedJSON(owner string, offset, limit int) string {
	offset, limit = page(offset, limit)
	who := address(strings.TrimSpace(owner))
	if !who.IsValid() {
		return "null"
	}
	items := []string{}
	seen := 0
	collections.IterateByOffset(offset, limit, func(key string, v any) bool {
		seen++
		col := v.(*collection)
		if col.list == nil {
			return false
		}
		n, err := col.token.BalanceOf(who)
		if err != nil || n <= 0 {
			return false
		}
		if n > maxOwnedPerCollection {
			n = maxOwnedPerCollection
		}
		operator := col.token.IsApprovedForAll(who, self)
		for i := int64(0); i < n; i++ {
			tid, err := col.list.TokenOfOwnerByIndex(who, i)
			if err != nil {
				break
			}
			approved := operator
			if !approved {
				if to, err := col.token.GetApproved(tid); err == nil && to == self {
					approved = true
				}
			}
			items = append(items, jsonObject(
				"key", jsonString(key),
				"name", jsonString(col.token.GetName()),
				"symbol", jsonString(col.token.GetSymbol()),
				"tokenId", jsonString(string(tid)),
				"approved", jsonBool(approved),
			))
		}
		return false
	})
	return jsonObject(
		"nfts", jsonArray(items),
		"more", jsonBool(offset+seen < collections.Size()),
	)
}

func tokenJSON(key string, tok *grc20.Token) string {
	return jsonObject(
		"key", jsonString(key),
		"name", jsonString(tok.GetName()),
		"symbol", jsonString(tok.GetSymbol()),
		"decimals", jsonInt(int64(tok.GetDecimals())),
		"verified", jsonBool(IsVerified(KindToken, key)),
	)
}

// json describes the room at block time now (unix seconds).
func (r *room) json(now int64) string {
	return jsonObject(
		"id", jsonUint(r.id),
		"status", jsonString(r.status),
		"expired", jsonBool(r.status == StatusOpen && now >= r.expiresAt),
		"version", jsonUint(r.version),
		"openSeat", jsonBool(r.openSeat),
		"openMarket", jsonBool(r.openMarket),
		"createdAt", jsonInt(r.createdAt),
		"expiresAt", jsonInt(r.expiresAt),
		"closedAt", jsonInt(r.closedAt),
		"closedBy", jsonString(r.closedBy.String()),
		"maker", r.maker.json(),
		"taker", r.taker.json(),
		"want", assetsJSON(r.want),
		"feeBps", jsonUint(r.feeBps),
		"now", jsonInt(now),
	)
}

func assetsJSON(list []asset) string {
	items := make([]string, 0, len(list))
	for _, a := range list {
		items = append(items, jsonObject(
			"kind", jsonString(a.kind),
			"denom", jsonString(a.denom),
			"amount", jsonString(jsonInt(a.amount)),
		))
	}
	return jsonArray(items)
}

func (s *side) json() string {
	return jsonObject(
		"address", jsonString(s.owner.String()),
		"locked", jsonUint(s.locked),
		"assets", assetsJSON(s.assets),
	)
}

func page(offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	return offset, limit
}
