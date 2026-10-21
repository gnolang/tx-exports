package game33

// ── Gasless relay: treasury pays gas for BuyTool and TrainSkill ──────────────
//
// The treasury server calls RelayBuyTool / RelayTrainSkill from the relay
// address (set by SetRelayAddress). Effects are recorded against `player`,
// not against the relay caller.
//
// Security model:
//   - relayAddress is the ONLY caller that may use these functions.
//   - Each call requires an ed25519 signature from the same claimSignerPubKey
//     used for claim vouchers. The server signs with MOJI_CLAIM_SIGNER_SEED.
//   - Replay protection: relayNonces[player] must increase monotonically.
//   - Expiry: relay vouchers expire within relayMaxTTL seconds.
//   - The relay cannot grant tools the player cannot normally buy (same
//     prerequisite and balance checks as BuyTool/TrainSkill).
//
// Relay voucher message (signed by the server, verified on-chain):
//   gnomoji-relay-v1|<chainId>|<kind>|<player>|<extra>|<nonce>|<expiry>
//
// Where:
//   kind  = "BuyTool" | "TrainSkill"
//   extra = toolId   (BuyTool) | skillId (TrainSkill)

import (
	"crypto/ed25519"
	"encoding/hex"
	"strconv"
	"time"

	"chain/runtime"

	"chain"
)

const relayMaxTTL = int64(300) // 5 minutes — relay vouchers are short-lived

// relayVoucherMessage builds the canonical message the server signs.
func relayVoucherMessage(kind, player, extra string, nonce, expiry int64) string {
	return "gnomoji-relay-v1|" + runtime.ChainID() + "|" + kind + "|" + player + "|" +
		extra + "|" + strconv.FormatInt(nonce, 10) + "|" + strconv.FormatInt(expiry, 10)
}

// lastRelayNonce returns the last relay nonce for player (0 if none).
func lastRelayNonce(player string) int64 {
	if !relayNonces.Has(player) {
		return 0
	}
	n, _ := strconv.ParseInt(relayNonces.Get(player).(string), 10, 64)
	return n
}

// useRelayVoucher verifies and consumes a relay voucher for player.
// Panics on any failure so the entire tx is rolled back.
func useRelayVoucher(kind, player, extra string, nonce, expiry int64, sigHex string) {
	if len(claimSignerPubKey) != 32 {
		panic("relay disabled: no claim signer configured")
	}
	now := time.Now().Unix()
	if expiry < now {
		panic("relay voucher expired")
	}
	if expiry > now+relayMaxTTL {
		panic("relay voucher expiry too far in the future")
	}
	lastN := lastRelayNonce(player)
	if nonce <= lastN {
		panic("relay voucher already used (nonce " + strconv.FormatInt(nonce, 10) + " ≤ last " + strconv.FormatInt(lastN, 10) + ")")
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != 64 {
		panic("invalid relay voucher signature encoding")
	}
	msg := relayVoucherMessage(kind, player, extra, nonce, expiry)
	if !ed25519.Verify(claimSignerPubKey, []byte(msg), sig) {
		panic("invalid relay voucher signature")
	}
	relayNonces.Set(player, strconv.FormatInt(nonce, 10))
}

// requireRelay panics unless the caller is the registered relay address.
func requireRelay(cur realm) {
	if relayAddress == address("") {
		panic("relay not configured: SetRelayAddress first")
	}
	if cur.Previous().Address() != relayAddress {
		panic("unauthorized: relay calls must come from the registered relay address")
	}
}

// ── Admin ─────────────────────────────────────────────────────────────────────

// SetRelayAddress registers the treasury wallet address as the relay.
// Pass "" to disable the relay.
func SetRelayAddress(cur realm, addr string) {
	requireAdmin(cur)
	if addr == "" {
		relayAddress = address("")
		return
	}
	a := address(addr)
	if !a.IsValid() {
		panic("invalid relay address")
	}
	relayAddress = a
	chain.Emit("RelayAddressSet", "relay", addr)
}

func RelayAddress() string { return relayAddress.String() }

// ── RelayBuyTool ──────────────────────────────────────────────────────────────

// RelayBuyTool executes BuyTool logic on behalf of `player` (the relay pays
// gas). The server must sign a relay voucher with MOJI_CLAIM_SIGNER_SEED:
//
//	gnomoji-relay-v1|<chainId>|BuyTool|<player>|<toolId>|<nonce>|<expiry>
//
// All prerequisites (coin balance, tool chain, existing ownership) are checked
// the same as BuyTool — the relay cannot bypass them.
func RelayBuyTool(cur realm, player string, toolId string, nonce int64, expiry int64, sigHex string) {
	requireRelay(cur)
	requireNotPaused()
	if isBlacklisted(player) {
		panic("player address is banned")
	}
	if !address(player).IsValid() {
		panic("invalid player address")
	}
	useRelayVoucher("BuyTool", player, toolId, nonce, expiry, sigHex)

	// ── BuyTool logic (identical to BuyTool but acts on `player`, not caller) ──
	costs, hasCost := toolCosts[toolId]
	if !hasCost {
		panic("unknown tool: " + toolId)
	}
	if ownsTool(player, toolId) {
		panic("already own " + toolId + " — use RepairTool to restore durability")
	}
	if prereq, ok := toolRequires[toolId]; ok && !ownsTool(player, prereq) {
		panic("must own " + prereq + " before buying " + toolId)
	}
	deductBalances(player, costs)

	if !ownedTools.Has(player) || ownedTools.Get(player).(string) == "" {
		ownedTools.Set(player, toolId)
	} else {
		ownedTools.Set(player, ownedTools.Get(player).(string)+","+toolId)
	}
	if mx, ok := toolMaxLife[toolId]; ok && mx > 0 {
		setU(&toolLife, player+":"+toolId, effectiveMaxLife(player, toolId))
	}
	chain.Emit("RelayedBuyTool", "player", player, "tool", toolId, "relay", cur.Previous().Address().String())
}

// ── RelayTrainSkill ───────────────────────────────────────────────────────────

// RelayTrainSkill executes TrainSkill logic on behalf of `player`.
// Relay voucher message:
//
//	gnomoji-relay-v1|<chainId>|TrainSkill|<player>|<skillId>|<nonce>|<expiry>
//
// Same checks as TrainSkill; max rank and coin deduction apply normally.
func RelayTrainSkill(cur realm, player string, skillId string, nonce int64, expiry int64, sigHex string) {
	requireRelay(cur)
	requireNotPaused()
	if isBlacklisted(player) {
		panic("player address is banned")
	}
	if !address(player).IsValid() {
		panic("invalid player address")
	}
	useRelayVoucher("TrainSkill", player, skillId, nonce, expiry, sigHex)

	// ── TrainSkill logic (identical to TrainSkill but acts on `player`) ──────
	key := player + ":" + skillId
	rank := getU(&skillRanks, key)
	maxRank, ok := skillMaxRanks[skillId]
	if !ok {
		panic("unknown skill: " + skillId)
	}
	if rank >= maxRank {
		panic("skill already at maximum rank")
	}
	baseCosts, ok := skillBaseCosts[skillId]
	if !ok {
		panic("unknown skill: " + skillId)
	}
	mult := uint64(1) << rank
	var scaled [][2]string
	for _, pair := range baseCosts {
		baseAmt, _ := strconv.ParseUint(pair[1], 10, 64)
		if s := baseAmt * mult; s > 0 {
			scaled = append(scaled, [2]string{pair[0], strconv.FormatUint(s, 10)})
		}
	}
	deductBalances(player, scaled)
	setU(&skillRanks, key, rank+1)
	chain.Emit("RelayedTrainSkill", "player", player, "skill", skillId, "relay", cur.Previous().Address().String())
}

// LastRelayNonce returns the last relay nonce used by addr (0 if none).
// Used by the server to compute the next nonce.
func LastRelayNonce(addr string) int64 { return lastRelayNonce(addr) }
