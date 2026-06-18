package gnobuilders_badges_v2

// gnobuilders_badges — GRC721 badge collection for GnoBuilders quests.
//
// Features:
//   - Admin-only minting (backend triggers mint after quest verification)
//   - Two badge types: Quest badges (transferable) and Rank badges (soulbound)
//   - Per-quest deduplication (one badge per quest per user)
//   - Standard GRC721: BalanceOf, OwnerOf, TokenURI, TransferFrom, Approve
//   - Render() contract for badge gallery display
//
// Security:
//   - Only admin can mint (prevents self-minting)
//   - Soulbound badges: TransferFrom panics for rank badges
//   - Owner can add/remove admins
//   - Token ID format: "{address}:{questId}" (globally unique)

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// ── Constants ────────────────────────────────────────────────

const (
	CollectionName   = "GnoBuilders Badges"
	CollectionSymbol = "GNOBADGE"
	MaxAdmins        = 10
)

// ── Types ────────────────────────────────────────────────────

type Badge struct {
	TokenID   string  // "{address}:{questId}"
	Owner     address
	QuestID   string
	TokenURI  string  // IPFS CID or URL to badge metadata JSON
	Soulbound bool    // true for rank badges (non-transferable)
	MintedAt  int64   // block height
}

// ── State ────────────────────────────────────────────────────

var (
	badges      *avl.Tree // tokenID -> *Badge
	ownerIndex  *avl.Tree // address -> comma-separated tokenIDs (secondary index)
	balances    *avl.Tree // address -> int (badge count)
	approvals   *avl.Tree // tokenID -> approved address
	opApprove   *avl.Tree // "owner:operator" -> bool (approval for all)
	admins      *avl.Tree // address -> bool
	// Owner is set at package load time via OriginCaller() — this captures the
	// deployer address (samcrew-core-test1 multisig on testnet).
	owner = unsafe.OriginCaller()
	totalMinted uint64
	paused      bool
)

func init() {
	badges = avl.NewTree()
	ownerIndex = avl.NewTree()
	balances = avl.NewTree()
	approvals = avl.NewTree()
	opApprove = avl.NewTree()
	admins = avl.NewTree()

	admins.Set(owner.String(), true)
}

// ── Emergency Pause ────────────────────────────────────────

func assertNotPaused() {
	if paused {
		panic("realm is paused — emergency maintenance")
	}
}

func Pause(cur realm) {
	assertCallerIsOwner()
	paused = true
}

func Unpause(cur realm) {
	assertCallerIsOwner()
	paused = false
}

func IsPaused() bool { return paused }

// ── GRC721 Standard ─────────────────────────────────────────

func Name() string   { return CollectionName }
func Symbol() string { return CollectionSymbol }

func TotalSupply() uint64 { return totalMinted }

func BalanceOf(addr address) uint64 {
	val, exists := balances.Get(addr.String())
	if !exists {
		return 0
	}
	return uint64(val.(int))
}

func OwnerOf(tokenID string) address {
	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found: " + tokenID)
	}
	return val.(*Badge).Owner
}

func TokenURI(tokenID string) string {
	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found: " + tokenID)
	}
	return val.(*Badge).TokenURI
}

func Approve(cur realm, approved address, tokenID string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found")
	}
	badge := val.(*Badge)
	if badge.Owner != caller {
		panic("only owner can approve")
	}
	if badge.Soulbound {
		panic("soulbound badges cannot be approved for transfer")
	}
	approvals.Set(tokenID, approved.String())

	// GRC721 Approval event
	chain.Emit("Approval",
		"owner", caller.String(),
		"approved", approved.String(),
		"tokenId", tokenID,
	)
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNotPaused()
	if operator == "" {
		panic("operator address cannot be empty")
	}
	caller := unsafe.PreviousRealm().Address()
	if operator == caller {
		panic("cannot approve self")
	}
	key := caller.String() + ":" + operator.String()
	if approved {
		opApprove.Set(key, true)
	} else {
		opApprove.Remove(key)
	}
}

func IsApprovedForAll(ownerAddr address, operator address) bool {
	key := ownerAddr.String() + ":" + operator.String()
	_, exists := opApprove.Get(key)
	return exists
}

func GetApproved(tokenID string) address {
	val, exists := approvals.Get(tokenID)
	if !exists {
		return ""
	}
	return address(val.(string))
}

func TransferFrom(cur realm, from address, to address, tokenID string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found")
	}
	badge := val.(*Badge)

	// Soulbound check
	if badge.Soulbound {
		panic("soulbound badges cannot be transferred")
	}

	// Auth check
	if badge.Owner != caller {
		approved := GetApproved(tokenID)
		if approved != caller && !IsApprovedForAll(from, caller) {
			panic("not authorized to transfer")
		}
	}

	if badge.Owner != from {
		panic("from address is not the owner")
	}

	// Transfer
	badge.Owner = to
	badges.Set(tokenID, badge)
	approvals.Remove(tokenID) // Clear approval

	// Update balances and owner index
	removeFromOwnerIndex(from, tokenID)
	addToOwnerIndex(to, tokenID)
	decBalance(from)
	incBalance(to)

	// GRC721 Transfer event
	chain.Emit("Transfer",
		"from", from.String(),
		"to", to.String(),
		"tokenId", tokenID,
	)
}

// ── Minting (Admin Only) ────────────────────────────────────

// MintQuestBadge mints a quest completion badge to a user.
// Token ID is "{address}:{questId}" to enforce one badge per quest per user.
// Quest badges are transferable by default.
func MintQuestBadge(cur realm, to address, questID string, tokenURI string) string {
	assertNotPaused()
	assertCallerIsAdmin()
	if len(questID) == 0 {
		panic("questID cannot be empty")
	}
	if containsChar(questID, ',') || containsChar(questID, ':') {
		panic("questID must not contain ',' or ':'")
	}

	tokenID := to.String() + ":" + questID

	// Check dedup
	if _, exists := badges.Get(tokenID); exists {
		panic("badge already minted for this quest: " + tokenID)
	}

	badge := &Badge{
		TokenID:   tokenID,
		Owner:     to,
		QuestID:   questID,
		TokenURI:  tokenURI,
		Soulbound: false,
		MintedAt:  runtime.ChainHeight(),
	}

	badges.Set(tokenID, badge)
	addToOwnerIndex(to, tokenID)
	incBalance(to)
	totalMinted++

	// GRC721 Transfer event from zero address (mint convention)
	chain.Emit("Transfer",
		"from", "",
		"to", to.String(),
		"tokenId", tokenID,
	)
	chain.Emit("QuestBadgeMinted",
		"to", to.String(),
		"questId", questID,
		"tokenId", tokenID,
	)

	return tokenID
}

// MintRankBadge mints a soulbound rank badge to a user.
// Token ID is "{address}:rank:{tier}" to enforce one rank badge per tier per user.
// Rank badges are NON-transferable (soulbound).
func MintRankBadge(cur realm, to address, tier int, tokenURI string) string {
	assertNotPaused()
	assertCallerIsAdmin()

	tokenID := to.String() + ":rank:" + strconv.Itoa(tier)

	// Check dedup
	if _, exists := badges.Get(tokenID); exists {
		panic("rank badge already minted for tier " + strconv.Itoa(tier))
	}

	badge := &Badge{
		TokenID:   tokenID,
		Owner:     to,
		QuestID:   "rank:" + strconv.Itoa(tier),
		TokenURI:  tokenURI,
		Soulbound: true,
		MintedAt:  runtime.ChainHeight(),
	}

	badges.Set(tokenID, badge)
	addToOwnerIndex(to, tokenID)
	incBalance(to)
	totalMinted++

	chain.Emit("Transfer",
		"from", "",
		"to", to.String(),
		"tokenId", tokenID,
	)
	chain.Emit("RankBadgeMinted",
		"to", to.String(),
		"tier", strconv.Itoa(tier),
		"tokenId", tokenID,
	)

	return tokenID
}

// UpdateTokenURI allows an admin to update the metadata URI of a badge.
// This is critical because realm code is immutable once deployed — if badge
// metadata needs correction (e.g., broken IPFS CID), this is the only mechanism.
func UpdateTokenURI(cur realm, tokenID string, newURI string) {
	assertNotPaused()
	assertCallerIsAdmin()
	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found: " + tokenID)
	}
	badge := val.(*Badge)
	badge.TokenURI = newURI
	badges.Set(tokenID, badge)
}

// ── Burn / Revoke ───────────────────────────────────────────

// BurnBadge permanently removes a badge. Admin-only for soulbound badges,
// owner or admin for transferable badges.
func BurnBadge(cur realm, tokenID string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	val, exists := badges.Get(tokenID)
	if !exists {
		panic("token not found: " + tokenID)
	}
	badge := val.(*Badge)

	if badge.Soulbound {
		// Soulbound: admin-only burn (revocation)
		assertCallerIsAdmin()
	} else {
		// Transferable: owner or admin can burn
		isAdmin := false
		if _, aok := admins.Get(caller.String()); aok {
			isAdmin = true
		}
		if badge.Owner != caller && !isAdmin {
			panic("only badge owner or admin can burn")
		}
	}

	badgeOwner := badge.Owner
	badges.Remove(tokenID)
	approvals.Remove(tokenID)
	removeFromOwnerIndex(badgeOwner, tokenID)
	decBalance(badgeOwner)
	if totalMinted > 0 {
		totalMinted--
	}

	// GRC721 Transfer event to zero address (burn convention)
	chain.Emit("Transfer",
		"from", badgeOwner.String(),
		"to", "",
		"tokenId", tokenID,
	)
}

// ── Admin Management ────────────────────────────────────────

func AddAdmin(cur realm, addr address) {
	assertCallerIsOwner()
	if addr == "" {
		panic("address cannot be empty")
	}
	if admins.Size() >= MaxAdmins {
		panic("admin limit reached")
	}
	admins.Set(addr.String(), true)
}

func RemoveAdmin(cur realm, addr address) {
	assertCallerIsOwner()
	if addr == owner {
		panic("cannot remove owner")
	}
	if _, exists := admins.Get(addr.String()); !exists {
		panic("address is not an admin: " + addr.String())
	}
	admins.Remove(addr.String())
}

// TransferOwnership transfers realm ownership. The old owner remains as admin
// (the new owner can call RemoveAdmin to revoke). This is intentional to prevent
// accidental lockout during multi-step ownership transfers.
func TransferOwnership(cur realm, newOwner address) {
	assertCallerIsOwner()
	if newOwner == "" {
		panic("address cannot be empty")
	}
	if newOwner == owner {
		panic("already owner")
	}
	admins.Set(newOwner.String(), true)
	owner = newOwner
}

func IsAdmin(addr address) bool {
	_, exists := admins.Get(addr.String())
	return exists
}

func GetOwner() address { return owner }

// ── Queries ─────────────────────────────────────────────────

// GetBadge returns badge info as a pipe-delimited string.
func GetBadge(tokenID string) string {
	val, exists := badges.Get(tokenID)
	if !exists {
		return ""
	}
	b := val.(*Badge)
	sb := strconv.FormatBool(b.Soulbound)
	return ufmt.Sprintf("%s|%s|%s|%s|%s|%d",
		b.TokenID, b.Owner, b.QuestID, b.TokenURI, sb, b.MintedAt)
}

// GetUserBadges returns all badge token IDs for a user as comma-separated string.
// Uses the ownerIndex for O(1) lookup instead of full table scan.
func GetUserBadges(addr address) string {
	val, exists := ownerIndex.Get(addr.String())
	if !exists {
		return ""
	}
	return val.(string)
}

// GetUserBadgeDetails returns full badge details for a user as a multi-line string.
// Each line: tokenID|owner|questID|tokenURI|soulbound|mintedAt
// This avoids N+1 queries from the frontend — one call returns all badge data.
func GetUserBadgeDetails(addr address) string {
	tokenIDsStr := GetUserBadges(addr)
	if tokenIDsStr == "" {
		return ""
	}

	var lines []string
	for _, tokenID := range strings.Split(tokenIDsStr, ",") {
		info := GetBadge(tokenID)
		if info != "" {
			lines = append(lines, info)
		}
	}
	return strings.Join(lines, "\n")
}

// ── Render ──────────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "badge/") {
		tokenID := strings.TrimPrefix(path, "badge/")
		return renderBadge(tokenID)
	}
	if strings.HasPrefix(path, "user/") {
		addr := strings.TrimPrefix(path, "user/")
		return renderUserBadges(addr)
	}
	return "# 404\nPage not found: " + path
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# GnoBuilders Badges\n\n")
	sb.WriteString(ufmt.Sprintf("**Collection:** %s (%s)\n", CollectionName, CollectionSymbol))
	sb.WriteString(ufmt.Sprintf("**Total Minted:** %d\n", totalMinted))
	sb.WriteString(ufmt.Sprintf("**Owner:** %s\n", owner))
	sb.WriteString(ufmt.Sprintf("**Admins:** %d\n\n", admins.Size()))

	// Recent badges (last 20)
	count := 0
	sb.WriteString("## Recent Badges\n\n")
	sb.WriteString("| Token | Quest | Owner | Soulbound |\n")
	sb.WriteString("|-------|-------|-------|-----------|\n")
	badges.ReverseIterate("", "", func(key string, value any) bool {
		if count >= 20 {
			return true
		}
		b := value.(*Badge)
		soul := ""
		if b.Soulbound {
			soul = "yes"
		}
		sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s |\n",
			truncStr(b.TokenID, 30), b.QuestID, truncAddr(b.Owner), soul))
		count++
		return false
	})

	return sb.String()
}

func renderBadge(tokenID string) string {
	val, exists := badges.Get(tokenID)
	if !exists {
		return "# Badge Not Found\nNo badge with ID: " + tokenID
	}
	b := val.(*Badge)
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Badge: %s\n\n", b.QuestID))
	sb.WriteString(ufmt.Sprintf("**Token ID:** %s\n", b.TokenID))
	sb.WriteString(ufmt.Sprintf("**Owner:** %s\n", b.Owner))
	sb.WriteString(ufmt.Sprintf("**Quest:** %s\n", b.QuestID))
	sb.WriteString(ufmt.Sprintf("**Soulbound:** %s\n", strconv.FormatBool(b.Soulbound)))
	sb.WriteString(ufmt.Sprintf("**Minted at block:** %d\n", b.MintedAt))
	if b.TokenURI != "" {
		sb.WriteString(ufmt.Sprintf("**Metadata:** %s\n", b.TokenURI))
	}
	return sb.String()
}

func renderUserBadges(addr string) string {
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Badges for %s\n\n", addr))

	// Use ownerIndex for O(1) lookup instead of full table scan
	tokenIDsStr := GetUserBadges(address(addr))
	if tokenIDsStr == "" {
		sb.WriteString("*No badges yet.*\n")
		return sb.String()
	}

	tokenIDs := strings.Split(tokenIDsStr, ",")
	for _, tokenID := range tokenIDs {
		val, exists := badges.Get(tokenID)
		if !exists {
			continue
		}
		b := val.(*Badge)
		soul := ""
		if b.Soulbound {
			soul = " (soulbound)"
		}
		sb.WriteString(ufmt.Sprintf("- **%s** — %s%s (block %d)\n",
			b.QuestID, truncStr(b.TokenURI, 40), soul, b.MintedAt))
	}

	return sb.String()
}

// ── Helpers ─────────────────────────────────────────────────

func assertCallerIsAdmin() {
	caller := unsafe.PreviousRealm().Address()
	if _, exists := admins.Get(caller.String()); !exists {
		panic("unauthorized: caller " + caller.String() + " is not an admin")
	}
}

func assertCallerIsOwner() {
	caller := unsafe.PreviousRealm().Address()
	if caller != owner {
		panic("unauthorized: caller " + caller.String() + " is not the owner")
	}
}

func incBalance(addr address) {
	val, exists := balances.Get(addr.String())
	if !exists {
		balances.Set(addr.String(), 1)
	} else {
		balances.Set(addr.String(), val.(int)+1)
	}
}

func decBalance(addr address) {
	val, exists := balances.Get(addr.String())
	if !exists {
		return
	}
	n := val.(int) - 1
	if n <= 0 {
		balances.Remove(addr.String())
	} else {
		balances.Set(addr.String(), n)
	}
}

func truncAddr(addr address) string {
	s := addr.String()
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

func truncStr(s string, maxLen int) string {
	if len(s) > maxLen {
		return s[:maxLen-3] + "..."
	}
	return s
}

// ── Owner Index Management ──────────────────────────────────

func addToOwnerIndex(addr address, tokenID string) {
	key := addr.String()
	val, exists := ownerIndex.Get(key)
	if !exists {
		ownerIndex.Set(key, tokenID)
	} else {
		ownerIndex.Set(key, val.(string)+","+tokenID)
	}
}

func containsChar(s string, ch rune) bool {
	for _, c := range s {
		if c == ch {
			return true
		}
	}
	return false
}

func removeFromOwnerIndex(addr address, tokenID string) {
	key := addr.String()
	val, exists := ownerIndex.Get(key)
	if !exists {
		return
	}
	ids := strings.Split(val.(string), ",")
	var remaining []string
	for _, id := range ids {
		if id != tokenID {
			remaining = append(remaining, id)
		}
	}
	if len(remaining) == 0 {
		ownerIndex.Remove(key)
	} else {
		ownerIndex.Set(key, strings.Join(remaining, ","))
	}
}
