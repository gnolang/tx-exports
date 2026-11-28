package bouncer

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Disputes. Anyone can challenge an attestation by paying a small deposit.
// An open dispute changes nothing by itself: it shows on the Passport and
// asks the scanner bot to scan the package again. When an attester has
// re-scanned, it settles the dispute (SettleDispute):
//
//   - a different report hash: upheld. The disputed attestation is marked
//     Disputed, which fails every policy that does not allow disputed
//     attestations (Strict, a bare Custom), and the deposit is refunded.
//   - the same report hash: rejected. Bouncer's scan reproduces exactly,
//     and the deposit stays with the realm.
//
// Reports are deterministic (same source, rule set and prover give the same
// bytes), so a re-scan differs only when the attested report was not what
// Bouncer produces. An admin or attester can also close a dispute by hand
// (ResolveDispute), which refunds the deposit and marks nothing.

// DisputeDeposit is the deposit for filing a dispute, in ugnot (1 GNOT).
const DisputeDeposit = int64(1_000_000)

// Dispute statuses.
const (
	DisputeOpen     = "open"
	DisputeUpheld   = "upheld"   // the re-scan's report differs
	DisputeRejected = "rejected" // the re-scan reproduced the attested report
	DisputeClosed   = "closed"   // closed by hand
)

// DisputeRecord is a challenge to an attestation.
type DisputeRecord struct {
	ID            uint64
	PkgPath       string
	AttestationID uint64 // the attestation disputed (the latest at filing time)
	ReportHash    string // the report the filer says is right
	Note          string
	Filer         address
	Deposit       int64 // ugnot held until the dispute is settled
	Height        int64
	Status        string
	RescanHash    string // the attester's re-scan report hash, once settled
	Resolution    string
	SettledBy     address
}

type dispute struct {
	d DisputeRecord
}

func disputeKey(id uint64) string { return seqid.ID(id).String() }

// openToRescan holds open disputes in filing order, for the scanner bot.
var openToRescan = avl.NewTree() // dispute id -> true

// Dispute files a challenge against the latest attestation of pkgpath,
// backed by a report with a different hash, with exactly DisputeDeposit
// ugnot sent along (gnokey maketx call -send 1000000ugnot). One open
// dispute per filer per package.
func Dispute(cur realm, pkgpath, reportHash, note string) uint64 {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	// The deposit must come from the filer's own transaction: only a
	// direct user call (not a maketx run script) guarantees the coins in
	// OriginSend reached this realm.
	if !cur.Previous().IsUserCall() {
		panic("file a dispute with a direct call (gnokey maketx call), sending the deposit")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent.AmountOf("ugnot") != DisputeDeposit {
		panic("a dispute needs a deposit of exactly " + strconv.FormatInt(DisputeDeposit, 10) + "ugnot")
	}
	filer := cur.Previous().Address()
	rec := getRecord(pkgpath)
	if rec == nil {
		panic("no attestation to dispute")
	}
	latest := rec.history[len(rec.history)-1]
	if !isHex64(reportHash) {
		panic("report hash must be 64 lowercase hex characters")
	}
	if reportHash == latest.ReportHash {
		panic("a dispute needs a report that differs from the attested one")
	}
	if note == "" || len(note) > maxNoteLen {
		panic("note must be 1 to 280 bytes")
	}
	if hasOpenDispute(pkgpath, filer) {
		panic("you already have an open dispute on this package")
	}
	id := uint64(disputeID.Next())
	disputes.Set(disputeKey(id), &dispute{d: DisputeRecord{
		ID:            id,
		PkgPath:       pkgpath,
		AttestationID: latest.ID,
		ReportHash:    reportHash,
		Note:          note,
		Filer:         filer,
		Deposit:       DisputeDeposit,
		Height:        runtime.ChainHeight(),
		Status:        DisputeOpen,
	}})
	setIn(disputesByPkg, pkgpath, disputeKey(id))
	openByFiler.Set(pkgpath+" "+filer.String(), true)
	openDisputes.Set(pkgpath, openDisputeCount(pkgpath)+1)
	openToRescan.Set(disputeKey(id), true)
	chain.Emit("Disputed", "id", disputeKey(id), "pkgpath", pkgpath, "filer", filer.String(), "report_hash", reportHash)
	return id
}

// SettleDispute records an attester's re-scan of a disputed package.
// rescanHash is the hash of the re-scan's full report. Attesters only.
func SettleDispute(cur realm, id uint64, rescanHash string) {
	attester := assertAttester(cur)
	if !isHex64(rescanHash) {
		panic("report hash must be 64 lowercase hex characters")
	}
	d := openDispute(id)
	a := attestationByID(d.d.PkgPath, d.d.AttestationID)
	d.d.RescanHash = rescanHash
	d.d.SettledBy = attester
	if rescanHash != a.ReportHash {
		a.Disputed = true
		closeDispute(cur, d, DisputeUpheld, "the re-scan's report differs from the attested one", true)
		return
	}
	closeDispute(cur, d, DisputeRejected, "the re-scan reproduced the attested report", false)
}

// ResolveDispute closes a dispute by hand, refunding the deposit and
// marking nothing: for a dispute no re-scan can settle, such as a package
// that can no longer be fetched. Admin or an attester.
func ResolveDispute(cur realm, id uint64, resolution string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address()
	if caller != admin && !attesters.Has(string(caller)) {
		panic("admin or attester only")
	}
	if resolution == "" || len(resolution) > maxNoteLen {
		panic("resolution must be 1 to 280 bytes")
	}
	d := openDispute(id)
	d.d.SettledBy = caller
	closeDispute(cur, d, DisputeClosed, resolution, true)
}

func openDispute(id uint64) *dispute {
	v := disputes.Get(disputeKey(id))
	if v == nil {
		panic("no such dispute")
	}
	d := v.(*dispute)
	if d.d.Status != DisputeOpen {
		panic("dispute already settled")
	}
	return d
}

// attestationByID returns the stored attestation (to mark it disputed).
func attestationByID(pkgpath string, id uint64) *Attestation {
	rec := getRecord(pkgpath)
	for i := range rec.history {
		if rec.history[i].ID == id {
			return &rec.history[i]
		}
	}
	panic("disputed attestation not found")
}

func closeDispute(cur realm, d *dispute, status, resolution string, refund bool) {
	d.d.Status = status
	d.d.Resolution = resolution
	p := d.d.PkgPath
	openByFiler.Remove(p + " " + d.d.Filer.String())
	if n := openDisputeCount(p) - 1; n > 0 {
		openDisputes.Set(p, n)
	} else {
		openDisputes.Remove(p)
	}
	openToRescan.Remove(disputeKey(d.d.ID))
	if refund {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), d.d.Filer, chain.Coins{{"ugnot", d.d.Deposit}})
	}
	chain.Emit("DisputeSettled", "id", disputeKey(d.d.ID), "pkgpath", p, "status", status)
}

// hasOpenDispute reports whether pkgpath has an open dispute (by filer, or
// by anyone if filer is ""). It reads indexes, never the list of every
// dispute, so disputes on other packages cannot make it more expensive.
func hasOpenDispute(pkgpath string, filer address) bool {
	if filer == "" {
		return openDisputeCount(pkgpath) > 0
	}
	return openByFiler.Has(pkgpath + " " + filer.String())
}

func openDisputeCount(pkgpath string) int {
	if v := openDisputes.Get(pkgpath); v != nil {
		return v.(int)
	}
	return 0
}

// OpenDisputes returns the number of open disputes on pkgpath.
func OpenDisputes(pkgpath string) int { return openDisputeCount(pkgpath) }

// OpenDisputesText lists up to limit open disputes for the scanner bot,
// oldest first, one line each: "id pkgpath source-hash rule-set-hash
// scanner-version toolchain", the last four from the disputed attestation.
// The bot settles a dispute only when it can re-scan under exactly those
// conditions; otherwise it attests afresh and closes the dispute by hand.
func OpenDisputesText(limit int) string {
	var b strings.Builder
	n := 0
	openToRescan.Iterate("", "", func(k string, _ any) bool {
		if n >= limit {
			return true
		}
		d := disputes.Get(k).(*dispute).d
		a := attestationByID(d.PkgPath, d.AttestationID)
		b.WriteString(strconv.FormatUint(d.ID, 10) + " " + d.PkgPath + " " + a.SourceHash + " " + a.RulesetHash + " " + a.ScannerVersion + " " + a.Toolchain + "\n")
		n++
		return false
	})
	return b.String()
}

// DisputesFor returns copies of every dispute on pkgpath, oldest first.
func DisputesFor(pkgpath string) []DisputeRecord {
	return recentDisputes(pkgpath, 0)
}

// recentDisputes returns copies of pkgpath's newest limit disputes (all if
// limit is 0), oldest first.
func recentDisputes(pkgpath string, limit int) []DisputeRecord {
	out := []DisputeRecord{}
	v := disputesByPkg.Get(pkgpath)
	if v == nil {
		return out
	}
	v.(*avl.Tree).ReverseIterate("", "", func(k string, _ any) bool {
		out = append(out, disputes.Get(k).(*dispute).d)
		return limit > 0 && len(out) >= limit
	})
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

// DisputeCount returns the number of disputes ever filed on pkgpath.
func DisputeCount(pkgpath string) int {
	if v := disputesByPkg.Get(pkgpath); v != nil {
		return v.(*avl.Tree).Size()
	}
	return 0
}
