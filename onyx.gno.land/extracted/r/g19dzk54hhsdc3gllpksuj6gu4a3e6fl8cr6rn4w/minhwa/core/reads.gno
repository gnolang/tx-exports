package core

import (
	"chain"
	"strings"

	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/types/v1"
)

// Every function in this file is read-only (I-12: no exported non-crossing
// mutator). Lists are paginated with limit <= MaxPageSize (RA L-4).

// SelfAddress is core's package address, for the deploy-time cross-check
// against scripts/pkgaddr.py (RA H-5).
func SelfAddress() address { return chain.PackageAddress(selfPath) }

func CollectionCount() int64 { return collCount }

// MintedTotal counts every token ever minted, burned ones included (OA B4).
func MintedTotal(cid string) int64 { return mustCollection(cid).minted() }

// MintedBy is the lifetime mint counter of addr in cid (OA B3, I-9).
func MintedBy(cid string, addr address) int64 { return mintedBy(mustCollection(cid), addr) }

// Info is the typed collection view for other realms.
func Info(cid string) types.CollectionInfo {
	c := mustCollection(cid)
	info := types.CollectionInfo{
		ID:          c.id,
		Name:        c.name,
		Symbol:      c.symbol,
		Description: c.description,
		Creator:     c.creator,
		Minter:      c.minter,
		EngineID:    c.engineID,
		Params:      c.params,
		State:       stateAt(c, height()),
		MaxSupply:   c.maxSupply,
		Minted:      c.minted(),
		Reserved:    c.reserved,
		StartHeight: c.startHeight,
		EndHeight:   c.endHeight,
		RoyaltyBps:  c.royaltyBps,
	}
	if c.prov != nil {
		info.RevealDeadline = revealDeadline(c)
		info.Badge = c.prov.badge
	}
	return info
}

// PrimaryPayees returns a copy of the frozen primary-sale split.
func PrimaryPayees(cid string) []types.Payee {
	return append([]types.Payee{}, mustCollection(cid).primaryPayees...)
}

// FeeConfig is the typed fee view minters and markets settle with.
func FeeConfig() types.Fees { return fees }

func Beacon() address { return beacon }

func Admin() address { return admin }

func IsMinter(path string) bool {
	v := minters.Get(path)
	return v != nil && !v.(*minterRecord).deprecated
}

// Collection is the collection record as JSON.
func Collection(cid string) string {
	w := &safe.JSONWriter{}
	writeCollection(w, mustCollection(cid))
	return w.String()
}

func Collections(offset, limit int64) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	collections.IterateByOffset(int(offset), int(clampLimit(limit)), func(_ string, v any) bool {
		writeCollection(w, v.(*collection))
		return false
	})
	w.EndArray()
	return w.String()
}

func CollectionsByCreator(creator address, offset, limit int64) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	prefix := creator.String() + ":"
	skipped, written, want := int64(0), int64(0), clampLimit(limit)
	byCreator.Iterate(prefix, prefix+"\xff", func(_ string, v any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		writeCollection(w, mustCollection(v.(string)))
		written++
		return written >= want
	})
	w.EndArray()
	return w.String()
}

// Fees is the fee configuration and its hard caps as JSON.
func Fees() string {
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.IntField("createFee", fees.CreateFee)
	w.IntField("primaryBps", fees.PrimaryBps)
	w.IntField("secondaryBps", fees.SecondaryBps)
	w.StrField("treasury", fees.Treasury.String())
	w.IntField("createFeeCap", CreateFeeCap)
	w.IntField("protocolFeeCapBps", ProtocolFeeCapBps)
	w.IntField("royaltyCapBps", RoyaltyCapBps)
	w.EndObject()
	return w.String()
}

// PendingOps is the timelock queue as JSON.
func PendingOps() string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	ops.Iterate("", "", func(_ string, v any) bool {
		p := v.(*pendingOp)
		w.BeginObject()
		w.StrField("id", itoa(p.id))
		w.StrField("op", p.op)
		w.StrField("arg", p.arg)
		w.IntField("proposed", p.proposed)
		w.IntField("earliest", earliestExecution(p))
		w.EndObject()
		return false
	})
	w.EndArray()
	return w.String()
}

func writeCollection(w *safe.JSONWriter, c *collection) {
	h := height()
	w.BeginObject()
	w.StrField("cid", c.id)
	w.StrField("name", c.name)
	w.StrField("symbol", c.symbol)
	w.StrField("description", c.description)
	w.StrField("creator", c.creator.String())
	w.StrField("engine", c.engineID)
	w.StrField("params", c.params)
	w.StrField("minter", c.minter)
	w.StrField("state", stateAt(c, h).String())
	w.IntField("maxSupply", c.maxSupply)
	w.IntField("minted", c.minted())
	w.IntField("reserved", c.reserved)
	w.IntField("royaltyBps", c.royaltyBps)
	w.StrField("royaltyAddress", royaltyAddress(c.id).String())
	w.StrField("primaryPayees", safe.FormatPayees(c.primaryPayees))
	w.StrField("royaltyPayees", safe.FormatPayees(c.royaltyPayees))
	w.IntField("startHeight", c.startHeight)
	w.IntField("endHeight", c.endHeight)
	w.IntField("createdHeight", c.createdHeight)
	w.StrField("token", c.token.ID())
	if c.prov != nil {
		w.IntField("revealDeadline", revealDeadline(c))
		w.BoolField("useBeacon", c.useBeacon)
		w.StrField("badge", c.prov.badge)
	}
	w.EndObject()
}

func clampLimit(limit int64) int64 {
	if limit <= 0 || limit > MaxPageSize {
		return MaxPageSize
	}
	return limit
}

// Render stays minimal in the immutable realm; the browsable gallery is the
// private, re-deployable gallery realm (design §2.5.7).
func Render(path string) string {
	gallery := strings.TrimPrefix(strings.TrimSuffix(selfPath, "/core")+"/gallery", "gno.land")
	return ufmt.Sprintf("# Collections ledger\n\n%d collections, %d engines. Browse them in the [gallery](%s).\n",
		collCount, engineCount, gallery)
}
