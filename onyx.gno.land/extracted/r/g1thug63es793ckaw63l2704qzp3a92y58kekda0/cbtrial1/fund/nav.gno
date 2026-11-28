package fund

import (
	"strconv"
	"strings"

	"gno.land/p/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fundmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// MaxMark bounds one instrument's mark (1,000,000,000,000 tUSD).
const MaxMark int64 = 1_000_000_000_000 * u

// MinNAVps: below 1 tUSD per share dealing is suspended (review I1).
const MinNAVps int64 = 1 * u

// CutOff closes the period to new orders and compliance decisions. The
// administrator, or anyone once the period has been open for a full
// dealing period (so one silent key cannot stop dealing).
func CutOff(cur realm) {
	assertMasterKey()
	requireLaunched()
	requireState(stateOpen)
	c := cur.Previous().Address()
	who := "administrator"
	if c != administrator {
		if now() < cur0.openedAt+PeriodSeconds {
			panic("administrator only until the period has run its full length")
		}
		who = "anyone (period ran its full length)"
	}
	cur0.state = stateCutOff
	cur0.cutAt = now()
	cur0.cutBy = who
	addTrail(who, ufmt.Sprintf("Period %d cut-off.", cur0.n))
	if windDownApproved && !windingDown {
		windingDown = true
		addTrail("settlement", "Wind-down in force from this cut-off.")
	}
}

// ProposeNAV submits the period's valuation. marks lists every listed
// instrument once, as NAME=value in tUSD micro-units, separated by ";"
// (e.g. "NOTE-X=61800000000;BILL-Y=0"). sourceRef is the SHA-256 of the
// price sources, kept off-chain. A new proposal replaces an unapproved one.
//
// The fees and expenses (management, administration, deposit bank, set-up
// costs) accrue on the real time since the last approved valuation, capped
// at one dealing period (review I5).
func ProposeNAV(cur realm, marks string, sourceRef string) int64 {
	onlyRole(cur, administrator, "administrator")
	if cur0.state != stateCutOff && cur0.state != stateProposed {
		panic("not allowed in state " + stateNames[cur0.state])
	}
	checkCommitment(sourceRef)
	parsed := parseMarks(marks)
	gross := bookCash
	for _, m := range parsed {
		gross = addChecked(gross, m.value)
	}
	S := sharesInIssue
	t := now()
	var mgmt, admin, bank, org int64
	if S > 0 && lastStrikeTime > 0 {
		elapsed := t - lastStrikeTime
		if elapsed > PeriodSeconds {
			elapsed = PeriodSeconds
		}
		if elapsed > 0 {
			mgmt = fundmath.AnnualCharge(gross, FeeBps, elapsed)
			admin = fundmath.AnnualCharge(gross, AdminFeeBps, elapsed)
			bank = fundmath.AnnualCharge(gross, BankFeeBps, elapsed)
			org = fundmath.MulDivDown(OrgCostTotal, elapsed, OrgCostPeriods*PeriodSeconds)
			if org > orgLeft {
				org = orgLeft
			}
		}
	}
	fee := mgmt + admin + bank + org
	nav := gross - totalOwed - fee
	navps := Par
	lowNAV := false
	if S > 0 {
		// A NAV of zero or less, or below 1 tUSD per share, is accepted: the
		// period deals nothing (outside a wind-down) but completes, so the
		// board can still act (review 3, I3).
		if nav <= 0 {
			navps, lowNAV = 0, true
		} else {
			navps = fundmath.MulDivDown(nav, u, S)
			lowNAV = navps < MinNAVps
		}
	}
	needsAck := false
	if S > 0 && lastNAVps > 0 {
		diff := navps - lastNAVps
		if diff < 0 {
			diff = -diff
		}
		needsAck = fundmath.MulDivDown(diff, fundmath.BpsDenominator, lastNAVps) > NAVToleranceBps
	} else if S > 0 && lastStrikeTime > 0 {
		needsAck = true // from a NAV per share of 0, any NAV needs acknowledgement (review 4, m1)
	}
	cur0.proposalNo++
	cur0.valuedAt = t
	cur0.marks, cur0.sourceRef = parsed, sourceRef
	cur0.gross, cur0.fee, cur0.nav, cur0.navps, cur0.needsAck = gross, fee, nav, navps, needsAck
	cur0.mgmtFee, cur0.adminFee, cur0.bankFee, cur0.orgFee = mgmt, admin, bank, org
	cur0.lowNAV = lowNAV
	cur0.state = stateProposed
	addTrail("administrator", ufmt.Sprintf("Period %d NAV proposal %d: gross %s, fees and expenses %s, NAV %s, NAV per share %s%s.",
		cur0.n, cur0.proposalNo, fmtAmt(gross), fmtAmt(fee), fmtAmt(nav), fmtAmt(navps), ackNote(needsAck)+lowNote(lowNAV)))
	return cur0.proposalNo
}

func lowNote(b bool) string {
	if b && !windingDown {
		return "; below 1 tUSD per share or not positive: no order is dealt this period"
	}
	return ""
}

func ackNote(b bool) string {
	if b {
		return " (move beyond tolerance: needs the reviewer's acknowledgement)"
	}
	return ""
}

// ApproveNAV countersigns proposal number `proposal`. A move beyond the
// tolerance needs acknowledgeMove = true. Settlement can then start.
func ApproveNAV(cur realm, proposal int64, acknowledgeMove bool) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateProposed)
	if proposal != cur0.proposalNo {
		panic("proposal number does not match the current proposal")
	}
	if cur0.needsAck && !acknowledgeMove {
		panic("NAV move beyond tolerance: acknowledgeMove must be true")
	}
	for _, m := range cur0.marks {
		getInstrument(m.name).book = m.value
	}
	cur0.sharesOpen = sharesInIssue
	cur0.state = stateSettling
	cur0.phase = 0
	cur0.fills = avl.NewTree()
	lastNAVps = cur0.navps
	lastStrikeTime = cur0.valuedAt
	addTrail("reviewer", ufmt.Sprintf("Period %d NAV proposal %d approved. NAV per share %s.", cur0.n, proposal, fmtAmt(cur0.navps)))
}

// RejectNAV sends the proposal back to the administrator with a reason code.
func RejectNAV(cur realm, proposal int64, reasonCode string) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateProposed)
	if proposal != cur0.proposalNo {
		panic("proposal number does not match the current proposal")
	}
	checkCode(reasonCode)
	cur0.state = stateCutOff
	addTrail("reviewer", ufmt.Sprintf("Period %d NAV proposal %d rejected: %s.", cur0.n, proposal, reasonCode))
}

func parseMarks(s string) []mark {
	if len(s) > 1024 {
		panic("marks too long")
	}
	seen := map[string]bool{}
	var out []mark
	for _, part := range strings.Split(s, ";") {
		kv := strings.Split(part, "=")
		if len(kv) != 2 {
			panic("marks: expected NAME=value")
		}
		name := kv[0]
		if !instruments.Has(name) {
			panic("marks: unknown instrument " + name)
		}
		if seen[name] {
			panic("marks: instrument listed twice: " + name)
		}
		v, err := strconv.ParseInt(kv[1], 10, 64)
		if err != nil || v < 0 || v > MaxMark {
			panic("marks: value must be an integer from 0 to 10^18 micro-units")
		}
		seen[name] = true
		out = append(out, mark{name, v})
	}
	if len(out) != len(instrOrder) {
		panic("marks: every listed instrument must be marked")
	}
	return out
}
