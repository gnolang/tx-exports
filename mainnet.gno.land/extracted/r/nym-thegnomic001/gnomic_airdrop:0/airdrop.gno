// Claim-based airdrop realm with Merkle proofs.
//
// Why Merkle rather than an on-chain list:
//   - the beneficiary list can run to tens of thousands of rows; writing it
//     on-chain costs gas and storage deposit in proportion;
//   - here only 32 bytes go on-chain (the root), plus one record per ACTUAL
//     claim. Whoever never claims costs nothing.
//
// Operating flow:
//  1. deploy this realm;
//  2. fund it by transferring GRC20 tokens to it (its address is returned by
//     RealmAddress());
//  3. the admin publishes root, leaf count and deadline block with SetCampaign;
//  4. each beneficiary calls Claim with their own proof;
//  5. after the deadline the admin recovers the residue with Sweep.
//
// The Merkle leaf is the string "<address>|<amount in base units>", UTF-8
// encoded. The tree is Tendermint's "simple tree" (gno's crypto/merkle):
// leaf = SHA256(0x00||data), node = SHA256(0x01||left||right), split at the
// largest power of two below n. The generator in tools/merkle produces
// compatible proofs.
package gnomic_airdrop

import (
	"chain"
	"math"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/merkle"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"

	// Realm of the distributed token. Transfers go through the registry to stay
	// decoupled, but BURNING needs the real realm: the registry exposes
	// Transfer/Approve/TransferFrom, not Burn. scripts/render.sh rewrites this
	// path with the actual token's one.
	token "gno.land/r/nym-thegnomic001/gnomic"
)

// Ownable holds the administrative authority over the campaign.
var Ownable *ownable.Ownable

// tokenKey is the key of the distributed token. It is a variable rather than a
// constant only so that tests can register one of their own; in production it
// keeps the config.gno value for the realm's whole life.
var tokenKey = defaultTokenKey

// claimWindowSeconds is a variable for the same reason: tests shrink or widen
// it. In production it keeps the config.gno value for the realm's whole life.
var claimWindowSeconds = defaultClaimWindowSeconds

// withdrawCooldownSeconds likewise: tests switch it off, production keeps it.
var withdrawCooldownSeconds = defaultWithdrawCooldownSeconds

var (
	root      []byte // Merkle root of the current campaign
	leafCount int    // total number of leaves (needed to verify)
	endHeight int64  // block past which no one can claim (0 = no limit)
	epoch     int    // bumped on every new campaign

	// claimed is the register of grants: "<address>" -> *grant.
	//
	// It is also the ONLY defence against double claiming. A Merkle proof shows
	// you are entitled, but it is reusable forever: only this register knows
	// that you have already collected.
	//
	// CAREFUL: never delete an entry, not even a settled one to reclaim its
	// storage deposit. It looks like a harmless optimisation and instead
	// reopens double claiming: someone who already withdrew everything would
	// present the same proof to a register that has forgotten them.
	claimed avl.Tree

	// campaignStart is when the current campaign opened: linear release runs
	// from there for EVERYONE, not from the moment of the individual claim.
	// Otherwise a late claimer would vest late, and there would be a reason to
	// rush to claim just to start the clock sooner.
	//
	// Every grant keeps a copy in grant.start: opening a new campaign must not
	// disturb the vesting already under way for whoever claimed in the
	// previous one.
	campaignStart int64

	// outstanding is the sum of what has been granted but not yet withdrawn.
	// It protects beneficiaries: Sweep cannot touch this part.
	outstanding int64

	// sealed makes opening further campaigns impossible. It is the equivalent
	// of DropOwnership on the token: a "one-off" airdrop announced in words
	// stays a promise; sealed in code it becomes a property anyone can verify
	// with a query.
	sealed bool

	totalClaimed  int64 // total actually paid out
	totalGranted  int64 // total granted (including what has not vested yet)
	totalBurned   int64 // total destroyed: instant exits, renunciations, settlement
	settledBurned int64 // burned by SettleUnclaimed
	settledToFund int64 // sent to the ecosystem fund by SettleUnclaimed
	totalToFund   int64 // sent to the ecosystem fund by voluntary forfeits
	claimCount    int
	realmAddr     address
)

// grant is the entitlement a beneficiary obtained in a campaign.
// It always holds that total == withdrawn + burned + toFund + (not yet released).
//
// Grants are keyed by address ALONE, not by "epoch:address": tying the key to
// the epoch made the previous campaign's grants unreachable as soon as a new
// one opened — the beneficiary could no longer withdraw and the tokens stayed
// counted in outstanding, so not even Sweep could recover them.
type grant struct {
	epoch        int   // campaign it was granted in
	start        int64 // start of this grant's vesting
	total        int64 // total amount granted
	withdrawn    int64 // how much has already been transferred
	burned       int64 // how much was destroyed (instant exit or forfeit)
	toFund       int64 // how much went to the ecosystem fund (forfeit)
	lastWithdraw int64 // unix time of the last payout; drives the cooldown
}

// settled reports whether nothing is left to pay out on the grant.
func (g *grant) settled() bool { return g.total <= g.withdrawn+g.burned+g.toFund }

// closed reports whether the grant was ended by an instant exit or a forfeit.
func (g *grant) closed() bool { return g.burned > 0 || g.toFund > 0 }

const (
	SealEvent     = "AirdropSeal"
	SettleEvent   = "AirdropSettleUnclaimed"
	ClaimEvent    = "AirdropClaim"
	WithdrawEvent = "AirdropWithdraw"
	ForfeitEvent  = "AirdropForfeit"
	CampaignEvent = "AirdropCampaign"
)

const bpsDenominator = 10000

func init(cur realm) {
	admin := address(adminAddress)
	if !admin.IsValid() {
		admin = cur.Previous().Address()
	}
	if !admin.IsValid() {
		admin = unsafe.OriginCaller()
	}
	if !admin.IsValid() {
		panic("airdrop: cannot determine the administrator")
	}
	Ownable = ownable.NewWithAddress(admin)
	realmAddr = cur.Address()

	// The registry key and the imported realm must name the SAME token.
	// Transfers go through the registry (by key) while burns call the imported
	// realm directly: if the two ever disagreed the airdrop would pay out one
	// token and destroy another, and nothing would notice until the first
	// forfeit. Deriving the key from the import makes them equal by
	// construction; the constant survives only to make a wrong TOKEN_KEY in
	// config.env fail here, at deploy, instead of silently in a year.
	tokenKey = token.TokenKey()
	if defaultTokenKey != tokenKey {
		panic("airdrop: config.gno names " + defaultTokenKey +
			" but the imported token realm is " + tokenKey)
	}
}

// ---------------------------------------------------------------------------
// Administration
// ---------------------------------------------------------------------------

// SetCampaign publishes a new campaign: rootHex is the Merkle root in hex
// (32 bytes), total the number of leaves in the tree, end the deadline block
// (0 = no deadline).
//
// Publishing a new campaign resets the claim history: whoever appears on both
// lists can claim again. That is deliberate — it allows recurring airdrops on
// the same realm without a redeploy.
func SetCampaign(cur realm, rootHex string, total int, end int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	if sealed {
		panic("airdrop: campaign is sealed, no further campaign can be opened")
	}

	raw, err := hex.DecodeString(strings.TrimPrefix(rootHex, "0x"))
	if err != nil {
		panic("airdrop: invalid root: " + err.Error())
	}
	if len(raw) != 32 {
		panic("airdrop: the root must be 32 bytes")
	}
	if total <= 0 {
		panic("airdrop: the leaf count must be positive")
	}
	if end != 0 && end <= runtime.ChainHeight() {
		panic("airdrop: the deadline must be in the future")
	}

	root = raw
	leafCount = total
	endHeight = end
	epoch++
	campaignStart = time.Now().Unix()

	chain.Emit(
		CampaignEvent,
		"epoch", strconv.Itoa(epoch),
		"root", hex.EncodeToString(raw),
		"leaves", strconv.Itoa(total),
		"end", strconv.FormatInt(end, 10),
	)
}

// CloseCampaign stops claims immediately.
func CloseCampaign(cur realm) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	// Dopo il sigillo non si chiude piu' niente. Il sigillo esiste per dire
	// "questi termini sono definitivi", e lasciare in mano al proprietario un
	// interruttore che toglie a tutti la possibilita' di rivendicare lo
	// contraddiceva: bastava chiudere e aspettare i dodici mesi perche' meta'
	// del non rivendicato bruciasse e meta' finisse al fondo. Prima del
	// sigillo la chiusura serve — e' il modo di rimediare a una radice
	// sbagliata — dopo non ha piu' nessun uso legittimo.
	if sealed {
		panic("airdrop: the campaign is sealed, it cannot be closed")
	}
	root = nil
	leafCount = 0
	endHeight = 0
}

// SealCampaign closes off the possibility of opening new campaigns forever.
// Irreversible: no code path sets sealed back to false. Call it once the
// published root is the final one.
//
// Until then the owner can fix a mistake by republishing the root; afterwards
// the airdrop is provably one-off and anyone can check with IsSealed().
func SealCampaign(cur realm) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	if sealed {
		panic("airdrop: already sealed")
	}
	if len(root) != 32 {
		panic("airdrop: no published root to seal")
	}
	sealed = true
	chain.Emit(SealEvent, "epoch", strconv.Itoa(epoch), "root", hex.EncodeToString(root))
}

// SettleUnclaimed disposes of whatever was never claimed, once the claim
// window has elapsed: half is burned, the other half goes to the team fund.
//
// The rule is enforced here rather than promised: there is no Sweep and no
// BurnRemaining, so the owner cannot pocket the residue nor destroy all of it.
// Settlement waits for the window even if CloseCampaign stopped claims
// earlier, and grants already made stay untouchable — only the free part
// (balance minus outstanding) is settled. Anyone may call it: it is a public
// service, not a privilege.
func SettleUnclaimed(cur realm) {
	if campaignStart == 0 {
		panic("airdrop: no campaign was ever opened")
	}
	if time.Now().Unix() < campaignStart+claimWindowSeconds {
		panic("airdrop: the claim window has not elapsed yet")
	}
	if isOpen() {
		panic("airdrop: the campaign is still open")
	}
	free := Balance() - outstanding
	if free <= 0 {
		panic("airdrop: no unclaimed residue to settle")
	}
	team := address(ecosystemFundAddress)
	if !team.IsValid() {
		panic("airdrop: ecosystem fund address is not configured")
	}
	burn := free / 2
	toTeam := free - burn
	totalBurned = addSat(totalBurned, burn)
	settledBurned = addSat(settledBurned, burn)
	settledToFund = addSat(settledToFund, toTeam)
	// Le due guardie non sono pedanteria: con un residuo di UNA unita' base
	// burn vale zero, e il ledger rifiuta un rogo di zero. Senza il controllo
	// la liquidazione fallirebbe per sempre proprio sul residuo piu' probabile
	// di tutti, quello lasciato dal troncamento, e quell'unita' resterebbe
	// chiusa nel realm senza che nessuno possa piu' toccarla.
	if burn > 0 {
		token.Burn(cross(cur), burn)
	}
	if toTeam > 0 {
		grc20reg.Transfer(0, cur, tokenKey, team, toTeam)
	}
	chain.Emit(SettleEvent,
		"burned", strconv.FormatInt(burn, 10),
		"to_team", strconv.FormatInt(toTeam, 10),
		"team", team.String())
}

// TransferOwnership hands administration of the campaign over.
func TransferOwnership(cur realm, newOwner address) {
	if err := Ownable.TransferOwnership(0, cur, newOwner); err != nil {
		panic(err.Error())
	}
}

// ---------------------------------------------------------------------------
// Claiming
// ---------------------------------------------------------------------------

// Claim pays amount tokens to the caller, if the Merkle proof
// (index, auntsHex) shows that "<caller>|<amount>" is a leaf of the published
// tree.
//
// auntsHex is the hex concatenation of the sibling hashes, 32 bytes each, just
// as produced by tools/merkle.
func Claim(cur realm, amount int64, index int, auntsHex string) {
	caller := cur.Previous().Address()
	if !cur.Previous().IsUserCall() {
		panic("airdrop: a claim must come from a user account")
	}
	claimFor(cur, caller, amount, index, auntsHex)
}

// claimFor is the body of Claim. It is unexported on purpose: a transaction
// can only reach exported functions, so from outside the realm the only way in
// is Claim, which always uses the caller's own address. The tests, being in
// the same package, still exercise the registration logic directly.
func claimFor(cur realm, beneficiary address, amount int64, index int, auntsHex string) {
	registerGrant(beneficiary, amount, index, auntsHex)
	releaseIfAny(cur, beneficiary)
}

// There is deliberately no "claim on behalf of" entry point.
//
// It used to exist, so that a third party could pay the gas for someone: the
// tokens went to the beneficiary either way, so it looked harmless. It is not.
// Registering the grant is what SPENDS the one choice this airdrop allows: the
// beneficiary can no longer take the instant 30%, nor renounce, because the
// vesting path has already been picked for them. A valid Merkle proof proves
// entitlement, never consent, and every proof is public.
//
// WithdrawFor stays: it only moves what has already vested to its owner, and
// takes no decision away from anyone.

// ClaimInstant is the first of the two alternatives to Claim: the instant
// share (instantBps, 30%) is paid at once and the rest (70%) is given up the
// same way a forfeit is — half burned, half to the ecosystem fund — whenever
// it is chosen, even after the whole grant would have vested. The share is
// larger than Claim's immediate 10% on purpose: it makes the shortcut a real
// choice rather than a punishment. It cannot be undone
// and suits someone who prefers a certain fraction today to the whole a year
// from now. The residue is destroyed, to every holder's benefit.
//
// Only the person concerned can choose it: there is no "on behalf of" form.
func ClaimInstant(cur realm, amount int64, index int, auntsHex string) {
	if !cur.Previous().IsUserCall() {
		panic("airdrop: a claim must come from a user account")
	}
	beneficiary := cur.Previous().Address()
	registerGrant(beneficiary, amount, index, auntsHex)
	g := grantOf(beneficiary)

	fund := address(ecosystemFundAddress)
	if !fund.IsValid() {
		panic("airdrop: ecosystem fund address is not configured")
	}
	immediate := shareOf(g.total, instantBps)
	rest := g.total - immediate
	burn := rest / 2
	toFund := rest - burn
	g.withdrawn = immediate
	g.burned = burn
	g.toFund = toFund
	g.lastWithdraw = time.Now().Unix()
	outstanding -= g.total
	totalClaimed = addSat(totalClaimed, immediate)
	totalBurned = addSat(totalBurned, burn)
	totalToFund = addSat(totalToFund, toFund)

	if immediate > 0 {
		grc20reg.Transfer(0, cur, tokenKey, beneficiary, immediate)
	}
	if burn > 0 {
		// Burn acts on the caller's balance: this realm holds the escrow.
		token.Burn(cross(cur), burn)
	}
	if toFund > 0 {
		grc20reg.Transfer(0, cur, tokenKey, fund, toFund)
	}
	chain.Emit(WithdrawEvent, "epoch", strconv.Itoa(epoch), "to", beneficiary.String(),
		"amount", strconv.FormatInt(immediate, 10), "remaining", "0")
	chain.Emit(ForfeitEvent, "epoch", strconv.Itoa(epoch), "who", beneficiary.String(),
		"burned", strconv.FormatInt(burn, 10), "to_fund", strconv.FormatInt(toFund, 10))
}

// Forfeit is the second alternative to Claim: the beneficiary gives the grant
// up without taking anything. Half is burned, half goes to the ecosystem fund —
// the same split SettleUnclaimed applies to whoever never acted at all.
//
// The proof is still required and the grant is still recorded: without that,
// the same address could forfeit and then claim. The record makes it final.
// Only the person concerned can choose it: there is no "on behalf of" form.
func Forfeit(cur realm, amount int64, index int, auntsHex string) {
	if !cur.Previous().IsUserCall() {
		panic("airdrop: a forfeit must come from a user account")
	}
	beneficiary := cur.Previous().Address()
	fund := address(ecosystemFundAddress)
	if !fund.IsValid() {
		panic("airdrop: ecosystem fund address is not configured")
	}
	registerGrant(beneficiary, amount, index, auntsHex)
	g := grantOf(beneficiary)

	burn := g.total / 2
	toFund := g.total - burn
	g.burned = burn
	g.toFund = toFund
	outstanding -= g.total
	totalBurned = addSat(totalBurned, burn)
	totalToFund = addSat(totalToFund, toFund)

	if burn > 0 {
		token.Burn(cross(cur), burn)
	}
	if toFund > 0 {
		grc20reg.Transfer(0, cur, tokenKey, fund, toFund)
	}
	chain.Emit(ForfeitEvent, "epoch", strconv.Itoa(epoch), "who", beneficiary.String(),
		"burned", strconv.FormatInt(burn, 10), "to_fund", strconv.FormatInt(toFund, 10))
}

// immediateOf is the share Claim unlocks at once: immediateBps/10000 of total.
func immediateOf(total int64) int64 { return shareOf(total, immediateBps) }

// shareOf is bps/10000 of total, in two steps to stay inside int64.
func shareOf(total int64, bps int) int64 {
	v := total/bpsDenominator*int64(bps) + total%bpsDenominator*int64(bps)/bpsDenominator
	if v > total {
		v = total
	}
	return v
}

// registerGrant checks the proof and records the grant. It transfers nothing.
func registerGrant(beneficiary address, amount int64, index int, auntsHex string) {
	if !isOpen() {
		panic("airdrop: no open campaign")
	}
	if !beneficiary.IsValid() {
		panic("airdrop: invalid beneficiary")
	}
	if amount <= 0 {
		panic("airdrop: invalid amount")
	}
	if index < 0 || index >= leafCount {
		panic("airdrop: index out of range")
	}

	key := beneficiary.String()
	if prev := grantOf(beneficiary); prev != nil {
		if prev.epoch == epoch {
			panic("airdrop: already claimed")
		}
		// A previous grant still vesting must not be overwritten: that would be
		// a silent loss for the beneficiary. It has to be closed first, with
		// Withdraw once vesting is over or with Forfeit.
		if !prev.settled() {
			panic("airdrop: an earlier grant is still running, close it first")
		}
	}

	aunts, err := hex.DecodeString(strings.TrimPrefix(auntsHex, "0x"))
	if err != nil {
		panic("airdrop: invalid proof: " + err.Error())
	}
	if len(aunts)%32 != 0 {
		panic("airdrop: the proof must be a multiple of 32 bytes")
	}

	leaf := []byte(Leaf(beneficiary, amount))
	if !merkle.VerifySimpleProof(root, leaf, index, leafCount, aunts) {
		panic("airdrop: invalid Merkle proof")
	}

	// The realm must be able to cover the new grant ON TOP of those already made.
	if Balance()-outstanding < amount {
		panic("airdrop: insufficient funds in the realm")
	}

	claimed.Set(key, &grant{epoch: epoch, start: campaignStart, total: amount})
	outstanding += amount
	totalGranted = addSat(totalGranted, amount)
	claimCount++

	chain.Emit(
		ClaimEvent,
		"epoch", strconv.Itoa(epoch),
		"to", beneficiary.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

// Withdraw transfers to the caller the vested, not-yet-withdrawn part.
func Withdraw(cur realm) {
	release(cur, cur.Previous().Address())
}

// WithdrawFor is like Withdraw but on another beneficiary's behalf: the tokens
// still go to beneficiary, whoever sends the transaction only pays the gas.
func WithdrawFor(cur realm, beneficiary address) {
	release(cur, beneficiary)
}

// release transfers the vested share. It is the public form: when there is
// nothing to withdraw it says so, instead of silently letting through a
// transaction that did nothing.
func release(cur realm, beneficiary address) {
	if releaseIfAny(cur, beneficiary) == 0 {
		panic("airdrop: nothing to withdraw right now")
	}
}

// releaseIfAny is the internal form: it transfers whatever has vested and
// returns the amount, or 0 if nothing has vested yet. It serves the paths where
// "nothing to withdraw" is normal rather than an error: a claim whose immediate
// share is zero, and a forfeit, whose point is to burn the residue rather than
// to collect.
// Payouts are rate-limited: one every withdrawCooldownSeconds per grant, the
// claim itself counting as the first. The very first payout is never delayed.
func releaseIfAny(cur realm, beneficiary address) int64 {
	g := grantOf(beneficiary)
	if g == nil {
		panic("airdrop: no grant for this address")
	}
	if g.closed() {
		panic("airdrop: grant closed by an instant exit or a forfeit")
	}
	amount := vestedOf(g) - g.withdrawn
	if amount <= 0 {
		return 0
	}
	now := time.Now().Unix()
	if g.lastWithdraw > 0 && now < g.lastWithdraw+withdrawCooldownSeconds {
		panic("airdrop: next withdrawal available in " +
			strconv.FormatInt(g.lastWithdraw+withdrawCooldownSeconds-now, 10) + " seconds")
	}

	g.lastWithdraw = now
	g.withdrawn += amount
	outstanding -= amount
	totalClaimed = addSat(totalClaimed, amount)

	grc20reg.Transfer(0, cur, tokenKey, beneficiary, amount)

	chain.Emit(
		WithdrawEvent,
		"epoch", strconv.Itoa(epoch),
		"to", beneficiary.String(),
		"amount", strconv.FormatInt(amount, 10),
		"remaining", strconv.FormatInt(g.total-g.withdrawn-g.burned-g.toFund, 10),
	)
	return amount
}

// vestedOf computes how much of a grant has vested:
//
//	vested = immediate + rest * elapsed / duration
//
// where immediate is immediateBps/10000 of the total. The division is done in
// two steps (quotient and remainder) because rest*elapsed would overflow int64
// for large amounts: 1e13 * 3.15e7 exceeds 9.2e18.
func vestedOf(g *grant) int64 {
	immediate := immediateOf(g.total)
	rest := g.total - immediate
	if rest == 0 || vestingSeconds <= 0 {
		return g.total
	}

	elapsed := time.Now().Unix() - g.start
	if elapsed <= 0 {
		return immediate
	}
	if elapsed >= vestingSeconds {
		return g.total
	}

	linear := rest/vestingSeconds*elapsed + rest%vestingSeconds*elapsed/vestingSeconds
	return immediate + linear
}

// addSat adds without ever wrapping. These counters only grow, across every
// campaign, and nothing bounds them to the supply: a statistic that turns
// negative would be bad, one that blocks a withdrawal would be worse.
func addSat(a, b int64) int64 {
	if b > 0 && a > math.MaxInt64-b {
		return math.MaxInt64
	}
	return a + b
}

func grantOf(addr address) *grant {
	v := claimed.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*grant)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

// Leaf returns the canonical Merkle-leaf encoding for the (address, amount)
// pair. It must match byte for byte the one used by the off-chain generator.
func Leaf(addr address, amount int64) string {
	return addr.String() + "|" + strconv.FormatInt(amount, 10)
}

// RealmAddress is the address to fund with the airdrop tokens.
func RealmAddress() address { return realmAddr }

// Balance is the token balance the realm currently holds.
func Balance() int64 {
	token := grc20reg.Get(tokenKey)
	if token == nil {
		return 0
	}
	return token.BalanceOf(realmAddr)
}

// Root returns the current Merkle root in hex.
func Root() string { return hex.EncodeToString(root) }

// Epoch is the number of the current campaign.
func Epoch() int { return epoch }

// IsSealed reports whether the campaign has been sealed: if true, no new
// campaign can ever be opened.
func IsSealed() bool { return sealed }

// LeafCount is the number of leaves in the published tree.
func LeafCount() int { return leafCount }

// EndHeight is the deadline block (0 = no deadline).
func EndHeight() int64 { return endHeight }

// IsOpen reports whether claims are currently accepted.
func IsOpen() bool { return isOpen() }

// HasClaimed reports whether addr has already claimed in the current campaign.
func HasClaimed(addr address) bool {
	g := grantOf(addr)
	return g != nil && g.epoch == epoch
}

// HasGrant reports whether addr holds a grant, from this campaign or an
// earlier one.
func HasGrant(addr address) bool { return grantOf(addr) != nil }

// GrantEpoch returns the campaign in which addr obtained its grant.
func GrantEpoch(addr address) int {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.epoch
}

// VestingStartOf returns when vesting starts for addr's grant.
func VestingStartOf(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.start
}

// ClaimedAmount returns addr's total grant, vested or not.
func ClaimedAmount(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.total
}

// Vested returns how much of addr's grant has vested so far. A closed grant
// (instant exit or forfeit) will never vest anything more: it reports what
// was paid, not where the curve would be.
func Vested(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	if g.closed() {
		return g.withdrawn
	}
	return vestedOf(g)
}

// InstantBps is the share ClaimInstant pays at once, in hundredths of a percent.
func InstantBps() int { return instantBps }

// Withdrawn returns how much addr has already withdrawn.
func Withdrawn(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.withdrawn
}

// Withdrawable returns how much addr can withdraw right now.
func Withdrawable(addr address) int64 {
	g := grantOf(addr)
	if g == nil || g.closed() {
		return 0
	}
	// During the cooldown the answer is zero, not "what has vested": this
	// function says what Withdraw would pay right now, and right now it would
	// refuse. NextWithdrawAt says when that changes.
	if g.lastWithdraw > 0 && time.Now().Unix() < g.lastWithdraw+withdrawCooldownSeconds {
		return 0
	}
	return vestedOf(g) - g.withdrawn
}

// NextWithdrawAt returns the unix time from which addr may withdraw again
// (0 when there is no grant, the grant is closed, or no cooldown is running).
func NextWithdrawAt(addr address) int64 {
	g := grantOf(addr)
	if g == nil || g.closed() || g.lastWithdraw == 0 {
		return 0
	}
	return g.lastWithdraw + withdrawCooldownSeconds
}

// WithdrawCooldown is the minimum interval between two payouts, in seconds.
func WithdrawCooldown() int64 { return withdrawCooldownSeconds }

// BurnedOf returns how much of addr's grant was destroyed.
func BurnedOf(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.burned
}

// FundOf returns how much of addr's grant went to the ecosystem fund.
func FundOf(addr address) int64 {
	g := grantOf(addr)
	if g == nil {
		return 0
	}
	return g.toFund
}

// TotalToFund is what voluntary forfeits sent to the ecosystem fund.
func TotalToFund() int64 { return totalToFund }

// TotalBurned is the total destroyed: instant exits, renunciations and the
// settlement of the unclaimed residue.
func TotalBurned() int64 { return totalBurned }

// ClaimWindowEnd is the moment (unix) claims stop being accepted for the
// current campaign; SettleUnclaimed becomes callable from then on.
func ClaimWindowEnd() int64 { return campaignStart + claimWindowSeconds }

// EcosystemFund is where the non-burned half of every forfeit goes.
func EcosystemFund() address { return address(ecosystemFundAddress) }

// SettledBurned and SettledToFund report what SettleUnclaimed did.
func SettledBurned() int64 { return settledBurned }
func SettledToFund() int64 { return settledToFund }

// Outstanding is the total granted and not yet withdrawn: the part of the
// realm's balance that Sweep cannot touch.
func Outstanding() int64 { return outstanding }

// TotalGranted is the total of all grants made, vested or not.
func TotalGranted() int64 { return totalGranted }

// VestingStart is the moment (unix) the CURRENT campaign's linear release runs
// from. Grants from earlier campaigns keep their own, readable with
// VestingStartOf.
func VestingStart() int64 { return campaignStart }

// VestingEnd is the moment (unix) at which everything granted in the current
// campaign counts as fully vested.
func VestingEnd() int64 { return campaignStart + vestingSeconds }

// ImmediateBps is the share unlocked at once, in hundredths of a percent.
func ImmediateBps() int { return immediateBps }

// TotalClaimed is the total actually transferred to beneficiaries.
func TotalClaimed() int64 { return totalClaimed }

// ClaimCount is the number of successful claims.
func ClaimCount() int { return claimCount }

func isOpen() bool {
	if len(root) != 32 || leafCount == 0 {
		return false
	}
	if endHeight != 0 && runtime.ChainHeight() > endHeight {
		return false
	}
	// The claim window is part of the deal: after it, no claim is accepted and
	// the residue is settled by SettleUnclaimed.
	if claimWindowSeconds > 0 && time.Now().Unix() >= campaignStart+claimWindowSeconds {
		return false
	}
	return true
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "claimed" {
		addr := address(parts[1])
		if !addr.IsValid() {
			return "invalid address\n"
		}
		g := grantOf(addr)
		if g == nil {
			return "no grant for this address\n"
		}
		if g.closed() {
			return ufmt.Sprintf(
				"granted: %d\nwithdrawn: %d\nburned: %d\nto fund: %d\nstatus: closed\n",
				g.total, g.withdrawn, g.burned, g.toFund)
		}
		return ufmt.Sprintf(
			"granted: %d\nvested: %d\nwithdrawn: %d\navailable now: %d\n",
			g.total, vestedOf(g), g.withdrawn, vestedOf(g)-g.withdrawn)
	}
	if path != "" {
		return "404\n"
	}

	s := ufmt.Sprintf("# %s\n\n", campaignName)
	s += "| | |\n|---|---|\n"
	s += ufmt.Sprintf("| Token | `%s` |\n", tokenKey)
	s += ufmt.Sprintf("| Realm address | `%s` |\n", realmAddr.String())
	s += ufmt.Sprintf("| Available balance | %d |\n", Balance())
	s += ufmt.Sprintf("| Campaign | #%d |\n", epoch)
	s += ufmt.Sprintf("| Status | %s |\n", statusLabel())
	s += ufmt.Sprintf("| Sealed | %s |\n", sealLabel())
	s += ufmt.Sprintf("| Merkle root | `%s` |\n", Root())
	s += ufmt.Sprintf("| Leaves | %d |\n", leafCount)
	s += ufmt.Sprintf("| Deadline (block) | %d |\n", endHeight)
	s += ufmt.Sprintf("| Claims | %d |\n", claimCount)
	s += ufmt.Sprintf("| Granted | %d |\n", totalGranted)
	s += ufmt.Sprintf("| Total paid out | %d |\n", totalClaimed)
	s += ufmt.Sprintf("| Burned | %d |\n", totalBurned)
	s += ufmt.Sprintf("| To the ecosystem fund (forfeits) | %d |\n", totalToFund)
	s += ufmt.Sprintf("| Still owed | %d |\n", outstanding)
	s += ufmt.Sprintf("| Current block | %d |\n", runtime.ChainHeight())
	s += "\n## Release\n\n"
	s += ufmt.Sprintf("- Unlocked immediately on claim: **%d%%**\n", immediateBps/100)
	s += ufmt.Sprintf("- The remaining **%d%%** vests linearly over %d days\n",
		100-immediateBps/100, vestingSeconds/86400)
	s += ufmt.Sprintf("- Withdrawals: at most one every %d hours per address, the claim counting as the first\n", withdrawCooldownSeconds/3600)
	s += ufmt.Sprintf("- Alternatively `ClaimInstant` pays exactly %d%% at once; of the other %d%%, half is **burned** and half goes to the ecosystem fund\n",
		instantBps/100, 100-instantBps/100)
	s += "- Or `Forfeit`: nothing paid, half burned, half to the ecosystem fund\n"
	s += ufmt.Sprintf("- Claims close %d days after opening; what was never claimed is then settled: **half burned, half to the ecosystem fund** (`%s`)\n",
		claimWindowSeconds/86400, ecosystemFundAddress)
	if settledBurned > 0 || settledToFund > 0 {
		s += ufmt.Sprintf("- Settled: %d burned, %d to the ecosystem fund\n", settledBurned, settledToFund)
	}
	if campaignStart > 0 {
		s += ufmt.Sprintf("- Start: %d, end: %d (unix)\n", campaignStart, VestingEnd())
		elapsed := time.Now().Unix() - campaignStart
		pct := int64(100)
		if elapsed < vestingSeconds {
			pct = elapsed * 100 / vestingSeconds
		}
		if pct < 0 {
			pct = 0
		}
		s += ufmt.Sprintf("- Progress: **%d%%**\n", pct)
	}
	s += "\nStatus of an address: `:claimed/<address>`\n"
	return s
}

// sealLabel describes in Render whether the airdrop is provably one-off.
func sealLabel() string {
	if sealed {
		return "**yes, one-off**: no new campaign is possible any more"
	}
	return "no: the owner can still republish the root"
}

func statusLabel() string {
	if isOpen() {
		return "**open**"
	}
	if len(root) == 32 {
		return "expired"
	}
	return "closed"
}
