// Package registry is the Assay on-chain package registry and execution
// escrow.
//
// Authors register a gno.land package together with its plain-text source
// and a per-call fee. Auditors mark packages as verified once the source has
// been reviewed. Callers then pay the fee with ExecuteAndPay: the realm checks
// the attached ugnot, forwards the fee to the author, refunds any excess and
// records an immutable receipt, all inside one transaction. If any check
// fails the whole transaction reverts and no GNOT moves.
package registry

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	denom         = "ugnot"
	maxFeePerCall = int64(1_000_000_000) // 1,000 GNOT
	maxSourceLen  = 64 * 1024
	maxDescLen    = 280
	maxPathLen    = 256
	maxRequestLen = 64
	recentLimit   = 20
	realmLink     = "/r/nym-assay001/registry"
)

// PackageMeta is everything the registry knows about a package.
type PackageMeta struct {
	Path         string
	Author       address
	Description  string
	SourceCode   string
	FeePerCall   int64
	TotalCalls   uint64
	TotalEarned  int64
	Verified     bool
	AuditNote    string
	RegisteredAt int64
}

// Receipt is the immutable record written by every successful ExecuteAndPay.
type Receipt struct {
	ID        uint64
	RequestID string
	PkgPath   string
	Caller    address
	Author    address
	Fee       int64
	Refund    int64
	Height    int64
}

var (
	admin      address
	auditors   = avl.NewTree() // address string -> bool
	packages   = avl.NewTree() // package path -> *PackageMeta
	receipts   = avl.NewTree() // zero-padded receipt id -> *Receipt
	requests   = avl.NewTree() // caller + "/" + request id -> receipt id (uint64)
	receiptSeq uint64
)

func init(cur realm) {
	admin = unsafe.OriginCaller()
	auditors.Set(admin.String(), true)
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

// RegisterPackage lists a package in the registry. The caller becomes its
// author and receives every fee paid for it. Re-registering a package you
// already own updates it and clears its verified flag, so changed source must
// be audited again.
func RegisterPackage(cur realm, pkgPath, description, sourceCode string, feePerCall int64) {
	caller := cur.Previous().Address()
	validatePath(pkgPath)
	if len(description) > maxDescLen {
		panic(ufmt.Sprintf("assay: description longer than %d bytes", maxDescLen))
	}
	if len(sourceCode) > maxSourceLen {
		panic(ufmt.Sprintf("assay: source longer than %d bytes", maxSourceLen))
	}
	if feePerCall < 0 || feePerCall > maxFeePerCall {
		panic(ufmt.Sprintf("assay: fee must be between 0 and %d ugnot", maxFeePerCall))
	}

	if existing, ok := packages.Get(pkgPath).(*PackageMeta); ok {
		if existing.Author != caller {
			panic("assay: package is owned by " + existing.Author.String())
		}
		existing.Description = description
		existing.SourceCode = sourceCode
		existing.FeePerCall = feePerCall
		existing.Verified = false
		existing.AuditNote = "source updated; awaiting re-audit"
		chain.Emit("AssayPackageUpdated", "pkg", pkgPath, "author", caller.String())
		return
	}

	packages.Set(pkgPath, &PackageMeta{
		Path:         pkgPath,
		Author:       caller,
		Description:  description,
		SourceCode:   sourceCode,
		FeePerCall:   feePerCall,
		AuditNote:    "awaiting audit",
		RegisteredAt: runtime.ChainHeight(),
	})
	chain.Emit("AssayPackageRegistered",
		"pkg", pkgPath,
		"author", caller.String(),
		"fee", strconv.FormatInt(feePerCall, 10),
	)
}

// SetVerified records an audit verdict. Only auditors may call it.
func SetVerified(cur realm, pkgPath string, verified bool, note string) {
	caller := cur.Previous().Address()
	if !isAuditor(caller) {
		panic("assay: caller is not an auditor")
	}
	if len(note) > maxDescLen {
		panic(ufmt.Sprintf("assay: note longer than %d bytes", maxDescLen))
	}
	meta := mustGet(pkgPath)
	meta.Verified = verified
	meta.AuditNote = note
	chain.Emit("AssayAudit",
		"pkg", pkgPath,
		"auditor", caller.String(),
		"verified", strconv.FormatBool(verified),
	)
}

// AddAuditor grants audit rights. Admin only.
func AddAuditor(cur realm, addr address) {
	assertAdmin(cur.Previous().Address())
	if !addr.IsValid() {
		panic("assay: invalid auditor address")
	}
	auditors.Set(addr.String(), true)
}

// RemoveAuditor revokes audit rights. Admin only.
func RemoveAuditor(cur realm, addr address) {
	assertAdmin(cur.Previous().Address())
	auditors.Remove(addr.String())
}

// TransferAdmin hands the admin role to another address. Admin only.
func TransferAdmin(cur realm, newAdmin address) {
	assertAdmin(cur.Previous().Address())
	if !newAdmin.IsValid() {
		panic("assay: invalid admin address")
	}
	admin = newAdmin
}

// ExecuteAndPay settles one paid call of a verified package and returns the
// receipt id. Send the fee with the transaction (gnokey -send 1000ugnot).
//
// requestID is chosen by the caller (a UUID works) and makes retries safe:
// if a payment succeeded but the client never saw the result, sending the
// same requestID again is refused with the original receipt number, and the
// refusal reverts, so the second deposit is returned.
//
// It must be called directly by a user: OriginSend describes the coins
// attached to the transaction, so letting another realm sit in between would
// let that realm spend someone else's deposit.
func ExecuteAndPay(cur realm, pkgPath, requestID string) uint64 {
	// Read-only checks first so callers get a precise reason. Any panic
	// reverts the whole transaction, so their order has no effect on funds.
	meta := mustGet(pkgPath)
	if !meta.Verified {
		panic("assay: package is not audit-verified; execution refused")
	}

	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != denom {
			panic("assay: only " + denom + " is accepted")
		}
	}
	paid := sent.AmountOf(denom)
	if paid < meta.FeePerCall {
		panic(ufmt.Sprintf("assay: insufficient fee: sent %d%s, required %d%s",
			paid, denom, meta.FeePerCall, denom))
	}

	if len(requestID) == 0 || len(requestID) > maxRequestLen {
		panic(ufmt.Sprintf("assay: request id must be 1 to %d bytes", maxRequestLen))
	}

	caller := cur.Previous().Address()
	reqKey := caller.String() + "/" + requestID
	if prev, seen := requests.Get(reqKey).(uint64); seen {
		panic("assay: duplicate request; already settled as receipt #" + strconv.FormatUint(prev, 10))
	}

	// Nothing moves until we know the signer called us directly.
	runtime.AssertOriginCall()

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := cur.Address()
	if meta.FeePerCall > 0 {
		b.SendCoins(self, meta.Author, chain.Coins{{denom, meta.FeePerCall}})
	}
	refund := paid - meta.FeePerCall
	if refund > 0 {
		b.SendCoins(self, caller, chain.Coins{{denom, refund}})
	}

	meta.TotalCalls++
	meta.TotalEarned += meta.FeePerCall

	receiptSeq++
	rcpt := &Receipt{
		ID:        receiptSeq,
		RequestID: requestID,
		PkgPath:   pkgPath,
		Caller:    caller,
		Author:    meta.Author,
		Fee:       meta.FeePerCall,
		Refund:    refund,
		Height:    runtime.ChainHeight(),
	}
	receipts.Set(receiptKey(receiptSeq), rcpt)
	requests.Set(reqKey, receiptSeq)

	chain.Emit("AssayExecution",
		"receipt", strconv.FormatUint(receiptSeq, 10),
		"request", requestID,
		"pkg", pkgPath,
		"caller", caller.String(),
		"author", meta.Author.String(),
		"fee", strconv.FormatInt(meta.FeePerCall, 10),
		"refund", strconv.FormatInt(refund, 10),
	)
	return receiptSeq
}

// ---------------------------------------------------------------------------
// Read-only queries
// ---------------------------------------------------------------------------

// Admin returns the current admin address.
func Admin() address { return admin }

// IsAuditor reports whether addr may record audit verdicts.
func IsAuditor(addr address) bool { return isAuditor(addr) }

// PackageCount returns the number of registered packages.
func PackageCount() int { return packages.Size() }

// ReceiptFor returns the receipt id a caller's request settled as, or 0.
// Lets a client that lost a response check before retrying.
func ReceiptFor(caller address, requestID string) uint64 {
	id, _ := requests.Get(caller.String() + "/" + requestID).(uint64)
	return id
}

// ReceiptCount returns the number of settled executions.
func ReceiptCount() uint64 { return receiptSeq }

// ---------------------------------------------------------------------------
// Render (gnoweb)
// ---------------------------------------------------------------------------

// Render serves:
//
//	""                 leaderboard of registered packages and recent receipts
//	"pkg/<path>"       package inspector, including the registered source
//	"receipts"         the latest receipts
//	"receipt/<id>"     a single receipt
//	"api/packages"     machine-readable JSON list (used by the MCP server and UI)
//	"api/package/<p>"  machine-readable JSON for one package, with source
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "receipts":
		return renderReceipts()
	case strings.HasPrefix(path, "receipt/"):
		return renderReceipt(strings.TrimPrefix(path, "receipt/"))
	case strings.HasPrefix(path, "pkg/"):
		return renderPackage(strings.TrimPrefix(path, "pkg/"))
	case path == "api/packages":
		return packagesJSON()
	case strings.HasPrefix(path, "api/package/"):
		meta, ok := packages.Get(strings.TrimPrefix(path, "api/package/")).(*PackageMeta)
		if !ok {
			return "null"
		}
		return packageJSON(meta, true)
	}
	return "404"
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Assay Registry\n\n")
	sb.WriteString("Verifiable package registry and execution escrow. Source is stored as plain text on chain; fees settle atomically in ugnot.\n\n")
	sb.WriteString(ufmt.Sprintf("**%d** packages · **%s** paid executions\n\n",
		packages.Size(), strconv.FormatUint(receiptSeq, 10)))

	sb.WriteString("## Leaderboard\n\n")
	list := sortedByEarnings()
	if len(list) == 0 {
		sb.WriteString("_No packages registered yet._\n\n")
	} else {
		sb.WriteString("| # | Package | Author | Fee (ugnot) | Calls | Earned (ugnot) | Audit |\n")
		sb.WriteString("|---|---|---|---:|---:|---:|---|\n")
		for i, m := range list {
			sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | `%s` | %s | %s | %s | %s |\n",
				i+1,
				mdEscape(m.Path), pkgLink(m.Path),
				shortAddr(m.Author),
				strconv.FormatInt(m.FeePerCall, 10),
				strconv.FormatUint(m.TotalCalls, 10),
				strconv.FormatInt(m.TotalEarned, 10),
				auditLabel(m.Verified),
			))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Recent receipts\n\n")
	sb.WriteString(receiptTable(recentLimit))
	return sb.String()
}

func renderReceipts() string {
	return "# Execution receipts\n\n" + receiptTable(recentLimit)
}

func renderReceipt(id string) string {
	n, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return "404"
	}
	r, ok := receipts.Get(receiptKey(n)).(*Receipt)
	if !ok {
		return "404"
	}
	return ufmt.Sprintf("# Receipt #%s\n\n- package: `%s`\n- caller: `%s`\n- author: `%s`\n- request: `%s`\n- fee: %s ugnot\n- refund: %s ugnot\n- block height: %s\n",
		strconv.FormatUint(r.ID, 10), r.PkgPath, r.Caller.String(), r.Author.String(), r.RequestID,
		strconv.FormatInt(r.Fee, 10), strconv.FormatInt(r.Refund, 10), strconv.FormatInt(r.Height, 10))
}

func renderPackage(pkgPath string) string {
	m, ok := packages.Get(pkgPath).(*PackageMeta)
	if !ok {
		return "404"
	}
	var sb strings.Builder
	sb.WriteString("# " + mdEscape(m.Path) + "\n\n")
	if m.Description != "" {
		sb.WriteString(mdEscape(m.Description) + "\n\n")
	}
	sb.WriteString("- author: `" + m.Author.String() + "`\n")
	sb.WriteString("- fee per call: " + strconv.FormatInt(m.FeePerCall, 10) + " ugnot\n")
	sb.WriteString("- calls: " + strconv.FormatUint(m.TotalCalls, 10) + "\n")
	sb.WriteString("- earned: " + strconv.FormatInt(m.TotalEarned, 10) + " ugnot\n")
	sb.WriteString("- audit: " + auditLabel(m.Verified) + " — " + mdEscape(m.AuditNote) + "\n")
	sb.WriteString("- registered at block: " + strconv.FormatInt(m.RegisteredAt, 10) + "\n\n")
	if m.SourceCode != "" {
		sb.WriteString("## Registered source\n\n```go\n" + m.SourceCode + "\n```\n")
	}
	return sb.String()
}

func receiptTable(limit int) string {
	if receipts.Size() == 0 {
		return "_No executions settled yet._\n"
	}
	var sb strings.Builder
	sb.WriteString("| Receipt | Package | Caller | Fee (ugnot) | Height |\n")
	sb.WriteString("|---|---|---|---:|---:|\n")
	n := 0
	receipts.ReverseIterate("", "", func(_ string, v any) bool {
		r := v.(*Receipt)
		sb.WriteString(ufmt.Sprintf("| [#%s](%s) | `%s` | `%s` | %s | %s |\n",
			strconv.FormatUint(r.ID, 10), receiptLink(r.ID),
			mdEscape(r.PkgPath), shortAddr(r.Caller),
			strconv.FormatInt(r.Fee, 10), strconv.FormatInt(r.Height, 10)))
		n++
		return n >= limit
	})
	return sb.String()
}

// ---------------------------------------------------------------------------
// JSON (hand-built; Gno has no encoding/json in realms)
// ---------------------------------------------------------------------------

func packagesJSON() string {
	var sb strings.Builder
	sb.WriteString("[")
	first := true
	packages.Iterate("", "", func(_ string, v any) bool {
		if !first {
			sb.WriteString(",")
		}
		first = false
		sb.WriteString(packageJSON(v.(*PackageMeta), false))
		return false
	})
	sb.WriteString("]")
	return sb.String()
}

func packageJSON(m *PackageMeta, withSource bool) string {
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"path":` + jsonString(m.Path))
	sb.WriteString(`,"author":` + jsonString(m.Author.String()))
	sb.WriteString(`,"description":` + jsonString(m.Description))
	sb.WriteString(`,"feePerCall":` + strconv.FormatInt(m.FeePerCall, 10))
	sb.WriteString(`,"totalCalls":` + strconv.FormatUint(m.TotalCalls, 10))
	sb.WriteString(`,"totalEarned":` + strconv.FormatInt(m.TotalEarned, 10))
	sb.WriteString(`,"verified":` + strconv.FormatBool(m.Verified))
	sb.WriteString(`,"auditNote":` + jsonString(m.AuditNote))
	sb.WriteString(`,"registeredAt":` + strconv.FormatInt(m.RegisteredAt, 10))
	if withSource {
		sb.WriteString(`,"sourceCode":` + jsonString(m.SourceCode))
	}
	sb.WriteString("}")
	return sb.String()
}

func jsonString(s string) string {
	const hex = "0123456789abcdef"
	var sb strings.Builder
	sb.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		default:
			if c < 0x20 {
				sb.WriteString(`\u00`)
				sb.WriteByte(hex[c>>4])
				sb.WriteByte(hex[c&0xf])
			} else {
				sb.WriteByte(c)
			}
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func validatePath(p string) {
	if len(p) == 0 || len(p) > maxPathLen {
		panic("assay: invalid package path length")
	}
	if !strings.HasPrefix(p, "gno.land/p/") && !strings.HasPrefix(p, "gno.land/r/") {
		panic("assay: package path must start with gno.land/p/ or gno.land/r/")
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '_' || c == '.' || c == '-'
		if !ok {
			panic("assay: package path contains an invalid character")
		}
	}
}

func mustGet(pkgPath string) *PackageMeta {
	m, ok := packages.Get(pkgPath).(*PackageMeta)
	if !ok {
		panic("assay: package not registered: " + pkgPath)
	}
	return m
}

func isAuditor(addr address) bool {
	return auditors.Has(addr.String())
}

func assertAdmin(addr address) {
	if addr != admin {
		panic("assay: caller is not the admin")
	}
}

// receiptKey zero-pads ids so the avl tree iterates in numeric order.
func receiptKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

// sortedByEarnings returns packages ordered by total earnings, then calls.
// Insertion sort keeps gas predictable for registry-sized lists.
func sortedByEarnings() []*PackageMeta {
	list := make([]*PackageMeta, 0, packages.Size())
	packages.Iterate("", "", func(_ string, v any) bool {
		list = append(list, v.(*PackageMeta))
		return false
	})
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && ranksAbove(list[j], list[j-1]); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	return list
}

func ranksAbove(a, b *PackageMeta) bool {
	if a.TotalEarned != b.TotalEarned {
		return a.TotalEarned > b.TotalEarned
	}
	return a.TotalCalls > b.TotalCalls
}

func auditLabel(verified bool) string {
	if verified {
		return "● verified"
	}
	return "○ unverified"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func pkgLink(pkgPath string) string {
	return realmLink + ":pkg/" + pkgPath
}

func receiptLink(id uint64) string {
	return realmLink + ":receipt/" + strconv.FormatUint(id, 10)
}

func mdEscape(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}
