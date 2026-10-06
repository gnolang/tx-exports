// GnoMoji — Minter Realm
// gno.land/r/gnomoji/minter
//
// Treasury gateway for GnoMoji on Gno.land (v1.5.0 / Onyx testnet API).
// Called server-side by treasury.server.ts after a player earns coins via ClaimMine.
//
// Security: only the admin (treasury wallet, set at deploy time) can call Mint or MintTool.

package minter3

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	admin    address
	mintLogs avl.Tree // addr+":"+coinId → total minted (audit)
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

func isAdmin(cur realm) bool {
	return cur.Previous().Address() == admin
}

// UpdateAdmin transfers the admin role to a new address.
func UpdateAdmin(cur realm, newAdmin string) {
	if !isAdmin(cur) {
		panic("minter: unauthorized")
	}
	admin = address(newAdmin)
}

// AdminAddr returns the current admin address.
func AdminAddr() string {
	return admin.String()
}

// ── Core minting ──────────────────────────────────────────────────────────────

// Mint credits coinId tokens to a player address.
// Records in internal audit log. Uncomment GRC20 cross-realm call once
// coin realms are deployed at gno.land/r/gnomoji/coins/{coinId}.
func Mint(cur realm, coinId string, toAddr string, amountStr string) {
	if !isAdmin(cur) {
		panic("minter: unauthorized — only treasury can mint")
	}
	if coinId == "" || toAddr == "" {
		panic("minter: coinId and toAddr required")
	}
	if !strings.HasPrefix(toAddr, "g1") {
		panic("minter: invalid Gno.land address")
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 {
		panic("minter: invalid amount")
	}

	key := toAddr + ":" + coinId
	existing := uint64(0)
	if mintLogs.Has(key) {
		existing, _ = strconv.ParseUint(mintLogs.Get(key).(string), 10, 64)
	}
	mintLogs.Set(key, strconv.FormatUint(existing+amount, 10))

	// Once GRC20 coin realms are deployed at gno.land/r/gnomoji/coins/{coinId},
	// uncomment to issue real on-chain tokens:
	//
	// coinPath := "gno.land/r/gnomoji/coins/" + coinId
	// std.Call(coinPath, "Mint", address(toAddr), amount)
}

// MintTool records tool ownership for a player on-chain.
func MintTool(cur realm, toolId string, toAddr string, _ string) {
	if !isAdmin(cur) {
		panic("minter: unauthorized — only treasury can mint tools")
	}
	if toolId == "" || toAddr == "" {
		panic("minter: toolId and toAddr required")
	}
	mintLogs.Set(toAddr+":tool:"+toolId, "1")
}

// ClearPendingMints notifies the game realm that coins have been minted.
func ClearPendingMints(cur realm, playerAddr string, coinsJson string) {
	if !isAdmin(cur) {
		panic("minter: unauthorized")
	}
	// Once game realm is deployed, uncomment:
	// std.Call("gno.land/r/gnomoji/game", "ClearPendingMints", playerAddr, coinsJson)
	_ = playerAddr
	_ = coinsJson
}

// ── Queries ───────────────────────────────────────────────────────────────────

func TotalMinted(playerAddr string, coinId string) string {
	key := playerAddr + ":" + coinId
	if mintLogs.Has(key) {
		return mintLogs.Get(key).(string)
	}
	return "0"
}

func Render(_ string) string {
	return ufmt.Sprintf(
		"# GnoMoji Minter\n\nAdmin: `%s`\n\nPath: `gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/minter3`\n\nUse Mint(coinId, addr, amount) to credit coins after ClaimMine.\n",
		admin.String(),
	)
}
