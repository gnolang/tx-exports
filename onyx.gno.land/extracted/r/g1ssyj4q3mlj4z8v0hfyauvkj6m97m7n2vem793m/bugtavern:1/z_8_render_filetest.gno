// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_8_render

package z_8_render

// SEND: 9500000ugnot

import (
	"chain"
	"testing"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
	"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

var sponsor = address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
var arbiter = address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")
var hunter = address("g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4")

const title = "Missing access control on Withdraw"
const poc = "https://example.com/poc"
const salt = "saltsaltsaltsalt"

func init(cur realm) {
	realmAddr := chain.PackageAddress("gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern")

	// Board with empty state.
	println("== empty board ==")
	println(bugtavern.Render(""))

	// One bounty, then the full §6.4 flow so every page has content.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	bountyID := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	println("== board with 1 bounty ==")
	println(bugtavern.Render(""))
	println("== bounty detail ==")
	println(bugtavern.Render("bounty/1"))

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	hash := tavernrules.MakeCommitment(bountyID, tavernrules.SevCritical, title, poc, salt)
	findingID := bugtavern.CommitFinding(cross(cur), bountyID, hash, uint8(tavernrules.SevCritical))
	testing.SetHeight(1002)
	bugtavern.RevealFinding(cross(cur), findingID, title, poc, salt)

	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept),
		uint8(tavernrules.SevCritical), "confirmed, drains vault", 0)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1004)
	bugtavern.MarkFixed(cross(cur), bountyID)

	println("== finding detail ==")
	println(bugtavern.Render("finding/1"))
	println("== hunter profile ==")
	println(bugtavern.Render("hunter/" + hunter.String()))
	println("== leaderboard ==")
	println(bugtavern.Render("leaderboard"))
	println("== ledger ==")
	println(bugtavern.Render("ledger"))
	println("== help ==")
	println(bugtavern.Render("help"))
	println("== not found ==")
	println(bugtavern.Render("bounty/999"))
}

func main() {
	println("done")
}

// Output:
// == empty board ==
// # BugTavern — Bug Bounty Keamanan untuk Realm Gno
//
// Version 0.4.0-day6.
//
// **Post a bounty:** [Create bounty](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=CreateBounty) · [How it works](#how-it-works) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// ## Totals
//
// | Open bounties | GNOT locked | GNOT paid out | Findings accepted |
// |---|---|---|---|
// | 0 | 0 | 0 | 0 |
//
// ## Open bounties
//
// No open bounties yet. Be the first sponsor: [create one](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=CreateBounty).
//
// ## Recently disclosed
//
// Nothing disclosed yet — disclosed findings appear here after the sponsor marks the bounty fixed.
//
// ## How it works
//
// 1. **Sponsor** locks a GNOT pool for their realm, with a price per severity tier.
// 2. **Hunter** commits a finding as a hash first (anti-front-running), then reveals the PoC.
// 3. **Arbiter** decides: Accept (escrow pays automatically), Duplicate, or Reject with a public reason.
// 4. If the arbiter stays silent, the sponsor decides; if both stay silent, the hunter claims the payout.
// 5. After the fix, the sponsor marks the bounty fixed and the finding is disclosed publicly.
//
// Full instructions, commands and costs: [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help).
//
// == board with 1 bounty ==
// # BugTavern — Bug Bounty Keamanan untuk Realm Gno
//
// Version 0.4.0-day6.
//
// **Post a bounty:** [Create bounty](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=CreateBounty) · [How it works](#how-it-works) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// ## Totals
//
// | Open bounties | GNOT locked | GNOT paid out | Findings accepted |
// |---|---|---|---|
// | 1 | 9.5 | 0 | 0 |
//
// ## Open bounties
//
// | # | Bounty | Scope | Pool left | Top tier | Arbiter | Deadline |
// |---|---|---|---|---|---|---|
// | 1 | [TavernVault audit](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/bounty/1) | Audit the vault realm for access control flaws\. | 9.5 GNOT | Critical 5 | `g1jg8m…pvwg` | ~1 days left |
//
// ## Recently disclosed
//
// Nothing disclosed yet — disclosed findings appear here after the sponsor marks the bounty fixed.
//
// ## How it works
//
// 1. **Sponsor** locks a GNOT pool for their realm, with a price per severity tier.
// 2. **Hunter** commits a finding as a hash first (anti-front-running), then reveals the PoC.
// 3. **Arbiter** decides: Accept (escrow pays automatically), Duplicate, or Reject with a public reason.
// 4. If the arbiter stays silent, the sponsor decides; if both stay silent, the hunter claims the payout.
// 5. After the fix, the sponsor marks the bounty fixed and the finding is disclosed publicly.
//
// Full instructions, commands and costs: [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help).
//
// == bounty detail ==
// # Bounty #1 — TavernVault audit
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// | Field | Value |
// |---|---|
// | Status | Open |
// | Sponsor | `g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m` |
// | Arbiter | `g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg` |
// | Scope | Audit the vault realm for access control flaws\. |
// | Pool total | 9.5 GNOT |
// | Pool left | 9.5 GNOT |
// | Paid out | 0 GNOT |
// | Refunded | 0 GNOT |
// | Critical | 5 GNOT |
// | High | 3 GNOT |
// | Medium | 1 GNOT |
// | Low | 0.5 GNOT |
// | Created | height 1000 |
// | Deadline | height 25600 (~1 days left) |
// | Accepted | 0 · Duplicates 0 · Rejected 0 |
//
// ## Findings on this bounty
//
// No findings yet.
//
// ## What can happen next
//
// - **Hunter — commit a finding:** [CommitFinding](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=CommitFinding&bountyID=1) — needs the commit hash (see [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help) for how to compute it).
// - **Sponsor — top up the pool:** [TopUpBounty](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=TopUpBounty&bountyID=1) (attach ugnot with the call).
// - **Sponsor — cancel this bounty:** [CancelBounty](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern$help&func=CancelBounty&bountyID=1) (refunds the remaining pool).
// ## Commands
//
// Commit a finding (severity 1 Low, 2 Medium, 3 High, 4 Critical):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func CommitFinding --args 1 --args "<sha256hex>" --args "4" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// Arbiter verdict (Accept pays the final tier):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func Verdict --args "<finding-id>" --args "1" --args "4" --args "confirmed" --args "0" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// Top up the pool (attach the exact top-up amount):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func TopUpBounty --args 1 --send 500000ugnot --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
//
// == finding detail ==
// # Finding #1 — Missing access control on Withdraw
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// | Field | Value |
// |---|---|
// | Bounty | [#1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/bounty/1) |
// | Hunter | [g1x582…uuq4](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/hunter/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4) |
// | Severity claimed | Critical |
// | Severity final | Critical |
// | Status | Disclosed |
// | Commit hash | `ceba4aa550e737510103fa7a74d5593628ca6afa4d5af1fe43e26ffe4e896c2c` |
// | Committed | height 1001 |
// | Reveal deadline | height 25601 |
// | Revealed | 1002 |
// | Review deadline | 73002 |
// | PoC | [https://example\.com/poc](https://example.com/poc) |
// | Verdict by | [g1jg8m…pvwg](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/hunter/g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg) |
// | Verdict at | 1003 |
// | Verdict reason | confirmed, drains vault |
// | Duplicate of | — |
// | Paid | 5 GNOT |
// | Disclosed | 1004 |
//
//
// == hunter profile ==
// # Hunter `g1x582…uuq4`
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// | Submitted | Accepted | Duplicates | Rejected | Earned |
// |---|---|---|---|---|
// | 1 | 1 | 0 | 0 | 5 GNOT |
//
// ## Findings
//
// | # | Bounty | Title | Severity | Status | Paid |
// |---|---|---|---|---|---|
// | [1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/finding/1) | [#1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/bounty/1) | Missing access control on Withdraw | Critical | Disclosed | 5 GNOT |
//
//
// == leaderboard ==
// # Leaderboard
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// Top hunters by accepted findings, then earned GNOT, then address.
//
// | Rank | Hunter | Accepted | Earned | Submitted | Duplicates |
// |---|---|---|---|---|---|
// | 1 | [g1x582…uuq4](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/hunter/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4) | 1 | 5 GNOT | 1 | 0 |
//
// ## Top arbiters
//
// | Arbiter | Verdicts | Accepted | Rejected | Duplicates | Timeouts |
// |---|---|---|---|---|---|
// | `g1jg8m…pvwg` | 1 | 1 | 0 | 0 | 0 |
//
// == ledger ==
// # Ledger — money trail
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// Every ugnot that entered or left the escrow, newest first. Tracked total: 2 entries.
//
// | Height | Bounty | Finding | Kind | To | Amount | Note |
// |---|---|---|---|---|---|---|
// | 1003 | [#1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/bounty/1) | [#1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/finding/1) | payout | [g1x582…uuq4](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/hunter/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4) | 5 GNOT | verdict accepted |
// | 1000 | [#1](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/bounty/1) | — | lock | [g1ssyj…793m](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/hunter/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m) | 9.5 GNOT | bounty created |
//
//
// == help ==
// # Help — how to use BugTavern
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// BugTavern is a bug-bounty escrow for Gno realms: sponsors lock GNOT, hunters report vulnerabilities (hash first, contents later), and an arbiter decides who gets paid.
//
// ## Sponsor
//
// 1. Create a bounty: lock the pool (the sum of the four tier prices) in one transaction.
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func CreateBounty --args "TavernVault audit" --args "gno.land/r/.../vault" --args "5000000" --args "3000000" --args "1000000" --args "500000" --args "<arbiter-address>" --args "24600" --send 9500000ugnot --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// Tier prices are in ugnot (1 GNOT = 1,000,000 ugnot). `24600` is the deadline in blocks (~1 day; minimum 24600, maximum 2214000, ~90 days). The arbiter may be a third-party auditor.
//
// 2. Top up the pool at any time while the bounty is Open (attach the top-up amount).
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func TopUpBounty --args "1" --send 500000ugnot --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 3. After the fix, mark the bounty fixed to disclose accepted findings:
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func MarkFixed --args "1" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 4. Cancel (no findings in flight) or close (after the deadline, no findings in flight) to refund the remaining pool:
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func CancelBounty --args "1" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 5. If the arbiter stays silent past the review window, you decide instead:
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func SponsorVerdict --args "1" --args "1" --args "4" --args "confirmed" --args "0" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// ## Hunter
//
// 1. Pick a salt (at least 16 random characters) and compute the commitment hash off-chain:
//
// ```
// echo -n "1|4|Missing access control on Withdraw|https://example.com/poc|<salt>" | sha256sum
// ```
//
// The format is `bountyID|severity|title|pocURL|salt` with severity 1 Low, 2 Medium, 3 High, 4 Critical. The example above hashes to `ceba4aa550e737510103fa7a74d5593628ca6afa4d5af1fe43e26ffe4e896c2c` with salt `saltsaltsaltsalt`.
//
// 2. Commit the hash (contents stay hidden):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func CommitFinding --args "1" --args "<sha256hex>" --args "4" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 3. Reveal within 24,600 blocks (~24h):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func RevealFinding --args "1" --args "Missing access control on Withdraw" --args "https://example.com/poc" --args "<salt>" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 4. If your finding is rejected, dispute once within 36,000 blocks (~36h):
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func DisputeFinding --args "1" --args "repro steps attached in PoC" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// 5. If the arbiter and then the sponsor both stay silent, claim the payout yourself:
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func ClaimPayout --args "1" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// ## Arbiter
//
// Decide a revealed finding within 72,000 blocks (~3 days) of the reveal. Accept pays the FINAL tier — you may correct the hunter's claimed severity up or down, and the price follows the corrected tier. Duplicate needs the original finding's id; Reject needs a reason.
//
// ```
// gnokey maketx call --pkgpath gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern --func Verdict --args "1" --args "1" --args "4" --args "confirmed, drains vault" --args "0" --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>
// ```
// ## Costs and limits
//
// - Storage deposit is 100 ugnot per byte of stored state; keep titles short.
// - Posting a bounty on Onyx costs roughly 0.65–0.76 GNOT (QuestMaster measurement — re-verify at deploy).
// - Title at most 100 characters; scope at most 1,000; PoC URL at most 300 and must start with `https://`; reasons at most 300.
// - Minimum bounty 1 GNOT; minimum tier price 0.1 GNOT; each tier pays at most once per bounty (first valid finding wins).
// - Windows (blocks): reveal 24,600 (~24h), arbiter review 72,000 (~3 days), sponsor 72,000, dispute 36,000 (~36h), disclosure 345,600 (~14 days).
//
// ## Known limitations
//
// - Arbiter–sponsor collusion cannot be prevented on-chain; verdicts and track records are public.
// - Finding contents become public at reveal — commit-reveal protects attribution and ordering, not eternal secrecy.
// - Severity judgement is human; the code only enforces the money.
// - The realm cannot be upgraded in place; a fix means a new realm path (see README).
//
// Source: https://github.com/lusiana27/bugtavern
//
// == not found ==
// # Not found
//
// There is no BugTavern page at `bounty/999`.
//
// [Board](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern) · [Leaderboard](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/leaderboard) · [Ledger](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/ledger) · [Help](/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/help)
//
// done

// Events:
// [
//   {
//     "type": "BountyCreated",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "sponsor",
//         "value": "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
//       },
//       {
//         "key": "pool_total",
//         "value": "9500000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingCommitted",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "severity",
//         "value": "Critical"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingRevealed",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "VerdictGiven",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "verdict",
//         "value": "Accept"
//       },
//       {
//         "key": "by",
//         "value": "g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingPaid",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "to",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "amount",
//         "value": "5000000"
//       },
//       {
//         "key": "how",
//         "value": "accepted"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "BountyFixed",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "disclosed",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
