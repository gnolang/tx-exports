package memba_dao_candidature_v2

// memba_dao_candidature — Membership application realm for MembaDAO.
//
// Provides a transparent, on-chain candidature flow:
//   1. Applicant calls Apply(bio, skills) with a deposit
//   2. Application is stored on-chain (visible to all)
//   3. Any DAO member can create an AddMember proposal referencing the application
//   4. DAO votes on the proposal (66% threshold)
//   5. If approved, member is added via basedao's built-in AddMember handler
//
// Anti-spam:
//   - Required deposit (10 GNOT default, 10x increase on re-application)
//   - Max bio/skills length (5000 chars)
//   - Cannot apply if already a member
//
// Security:
//   - Deposits are held in the realm until withdrawn by applicant
//   - MarkApproved/MarkRejected restricted to admin allowlist (owner-managed)
//   - Owner can add/remove admins and transfer ownership
//   - Admin cap of 20 addresses to limit blast radius

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

// ── Constants ────────────────────────────────────────────────

const (
	MinDeposit      int64 = 10_000_000 // 10 GNOT in ugnot
	DepositMultiply int64 = 10         // 10x on re-application
	MaxApplyCount         = 10         // Maximum re-applications (prevents int64 overflow at 10^17)
	MaxBioLen             = 5000
	MaxSkillsLen          = 5000
	MaxAdmins             = 20   // Maximum number of admin addresses
	MaxApplications       = 1000 // Global cap to prevent unbounded state growth
)

// ── Types ────────────────────────────────────────────────────

type Application struct {
	Address    address
	Bio        string
	Skills     string
	Deposit    int64
	Status     string // "pending", "approved", "rejected", "withdrawn"
	AppliedAt  int64  // block height
	ApplyCount int    // number of times applied (for deposit scaling)
}

// ── State ────────────────────────────────────────────────────

var (
	applications *avl.Tree // address -> *Application
	applyCount   *avl.Tree // address -> int (total apply count, persists across withdrawals)
	admins       *avl.Tree // address -> bool (authorized callers for MarkApproved/MarkRejected)
	paused       bool
	// Owner is set at package load time via OriginCaller() — this captures the
	// deployer address (samcrew-core-test1 multisig on testnet).
	owner = unsafe.OriginCaller()
)

func init() {
	applications = avl.NewTree()
	applyCount = avl.NewTree()
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

// ── Public API ───────────────────────────────────────────────

// Apply submits a membership application with a deposit.
// The caller must send at least MinDeposit * (10 ^ previousAttempts) ugnot.
func Apply(cur realm, bio string, skills string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	// Validate inputs
	if len(bio) == 0 {
		panic("bio cannot be empty")
	}
	if len(bio) > MaxBioLen {
		panic(ufmt.Sprintf("bio too long: %d/%d chars", len(bio), MaxBioLen))
	}
	if len(skills) > MaxSkillsLen {
		panic(ufmt.Sprintf("skills too long: %d/%d chars", len(skills), MaxSkillsLen))
	}

	// Check for existing pending application
	isNewApplicant := true
	if val, exists := applications.Get(caller.String()); exists {
		isNewApplicant = false
		app := val.(*Application)
		if app.Status == "pending" {
			panic("you already have a pending application")
		}
	}
	// Enforce global cap only for truly new applicants (not re-applications)
	if isNewApplicant && applications.Size() >= MaxApplications {
		panic(ufmt.Sprintf("application limit reached: %d", MaxApplications))
	}

	// Calculate required deposit (10x per previous attempt, capped to prevent overflow)
	count := getApplyCount(caller)
	if count >= MaxApplyCount {
		panic(ufmt.Sprintf("maximum re-application limit reached (%d)", MaxApplyCount))
	}
	required := MinDeposit
	for i := 0; i < count; i++ {
		required *= DepositMultiply
	}

	// Verify deposit (accumulate to handle multi-denom entries defensively)
	sent := unsafe.OriginSend()
	sentAmount := int64(0)
	for _, coin := range sent {
		if coin.Denom == "ugnot" {
			sentAmount += coin.Amount
		}
	}
	if sentAmount < required {
		panic(ufmt.Sprintf("insufficient deposit: sent %d, required %d ugnot", sentAmount, required))
	}

	// Store application
	app := &Application{
		Address:    caller,
		Bio:        bio,
		Skills:     skills,
		Deposit:    sentAmount,
		Status:     "pending",
		AppliedAt:  runtime.ChainHeight(),
		ApplyCount: count + 1,
	}
	applications.Set(caller.String(), app)
	applyCount.Set(caller.String(), count+1)

	chain.Emit("ApplicationSubmitted",
		"applicant", caller.String(),
		"deposit", strconv.FormatInt(sentAmount, 10),
		"attempt", strconv.Itoa(count+1),
	)
}

// Withdraw allows an applicant to withdraw their pending application and reclaim deposit.
func Withdraw(cur realm) {
	caller := unsafe.PreviousRealm().Address()

	val, exists := applications.Get(caller.String())
	if !exists {
		panic("no application found")
	}
	app := val.(*Application)
	if app.Status != "pending" {
		panic("can only withdraw pending applications")
	}

	// STATE-BEFORE-SEND: update status and zero deposit before coin transfer
	app.Status = "withdrawn"
	deposit := app.Deposit
	app.Deposit = 0
	applications.Set(caller.String(), app)

	// Return deposit
	if deposit > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(unsafe.CurrentRealm().Address(), caller, chain.Coins{chain.NewCoin("ugnot", deposit)})
	}
}

// MarkApproved is called by authorized admins to mark an application as approved.
// Only addresses in the admin allowlist can call this function.
func MarkApproved(cur realm, applicant address) {
	assertCallerIsAdmin()

	val, exists := applications.Get(applicant.String())
	if !exists {
		panic("no application found for " + applicant.String())
	}
	app := val.(*Application)
	if app.Status != "pending" {
		panic("application is not pending")
	}
	// STATE-BEFORE-SEND: update status before returning deposit
	app.Status = "approved"
	deposit := app.Deposit
	app.Deposit = 0
	applications.Set(applicant.String(), app)

	// Return deposit on approval (same as rejection)
	if deposit > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(unsafe.CurrentRealm().Address(), applicant, chain.Coins{chain.NewCoin("ugnot", deposit)})
	}

	chain.Emit("ApplicationApproved",
		"applicant", applicant.String(),
		"approvedBy", unsafe.PreviousRealm().Address().String(),
	)
}

// MarkRejected is called by authorized admins to mark an application as rejected.
// Only addresses in the admin allowlist can call this function.
func MarkRejected(cur realm, applicant address) {
	assertCallerIsAdmin()

	val, exists := applications.Get(applicant.String())
	if !exists {
		panic("no application found for " + applicant.String())
	}
	app := val.(*Application)
	if app.Status != "pending" {
		panic("application is not pending")
	}
	// STATE-BEFORE-SEND: update status and zero deposit before coin transfer
	app.Status = "rejected"
	deposit := app.Deposit
	app.Deposit = 0
	applications.Set(applicant.String(), app)

	// Return deposit on rejection
	if deposit > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(unsafe.CurrentRealm().Address(), applicant, chain.Coins{chain.NewCoin("ugnot", deposit)})
	}

	chain.Emit("ApplicationRejected",
		"applicant", applicant.String(),
		"rejectedBy", unsafe.PreviousRealm().Address().String(),
	)
}

// ── Admin Management ────────────────────────────────────────

// AddAdmin adds an address to the admin allowlist. Only the owner can call this.
func AddAdmin(cur realm, addr address) {
	assertCallerIsOwner()
	assertValidAddress(addr)
	if admins.Size() >= MaxAdmins {
		panic(ufmt.Sprintf("admin limit reached: %d/%d", admins.Size(), MaxAdmins))
	}
	admins.Set(addr.String(), true)
}

// RemoveAdmin removes an address from the admin allowlist. Only the owner can call this.
func RemoveAdmin(cur realm, addr address) {
	assertCallerIsOwner()
	if addr == owner {
		panic("cannot remove owner from admins")
	}
	if _, exists := admins.Get(addr.String()); !exists {
		panic("address is not an admin: " + addr.String())
	}
	admins.Remove(addr.String())
}

// TransferOwnership transfers realm ownership to a new address.
// The new owner is also added as admin. The old owner remains as admin
// (the new owner can remove them via RemoveAdmin if desired).
// Only the current owner can call this.
func TransferOwnership(cur realm, newOwner address) {
	assertCallerIsOwner()
	assertValidAddress(newOwner)
	if newOwner == owner {
		panic("new owner is the same as current owner")
	}
	admins.Set(newOwner.String(), true)
	owner = newOwner
}

// IsAdmin returns whether an address is in the admin allowlist.
func IsAdmin(addr address) bool {
	_, exists := admins.Get(addr.String())
	return exists
}

// GetOwner returns the current realm owner address.
func GetOwner() address {
	return owner
}

// ListAdmins returns all admin addresses as a comma-separated string.
func ListAdmins() string {
	var addrs []string
	admins.Iterate("", "", func(key string, value any) bool {
		addrs = append(addrs, key)
		return false
	})
	return strings.Join(addrs, ",")
}

// ── Queries ──────────────────────────────────────────────────

// GetApplication returns the application for a given address (or empty if none).
func GetApplication(addr string) string {
	val, exists := applications.Get(addr)
	if !exists {
		return ""
	}
	app := val.(*Application)
	return ufmt.Sprintf("%s|%s|%s|%d|%s|%d|%d",
		app.Address, app.Bio, app.Skills, app.Deposit, app.Status, app.AppliedAt, app.ApplyCount)
}

// ── Render ───────────────────────────────────────────────────

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "application/") {
		addr := strings.TrimPrefix(path, "application/")
		return renderApplication(addr)
	}
	return "# 404\nPage not found: " + path
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# MembaDAO Candidature\n\n")
	sb.WriteString("Apply to join the Memba community.\n\n")

	// Count by status
	pending, approved, rejected := 0, 0, 0
	applications.Iterate("", "", func(key string, value any) bool {
		app := value.(*Application)
		switch app.Status {
		case "pending":
			pending++
		case "approved":
			approved++
		case "rejected":
			rejected++
		}
		return false
	})

	sb.WriteString(ufmt.Sprintf("**Stats:** %d pending | %d approved | %d rejected\n", pending, approved, rejected))
	sb.WriteString(ufmt.Sprintf("**Owner:** %s | **Admins:** %d\n\n", owner, admins.Size()))

	// List pending applications
	if pending > 0 {
		sb.WriteString("## Pending Applications\n\n")
		applications.Iterate("", "", func(key string, value any) bool {
			app := value.(*Application)
			if app.Status == "pending" {
				sb.WriteString(ufmt.Sprintf("- [%s](:application/%s) — deposit: %s GNOT — block %d\n",
					app.Address, app.Address, formatGNOT(app.Deposit), app.AppliedAt))
			}
			return false
		})
	}

	return sb.String()
}

func renderApplication(addr string) string {
	val, exists := applications.Get(addr)
	if !exists {
		return "# Application Not Found\nNo application for " + addr
	}
	app := val.(*Application)

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Application: %s\n\n", app.Address))
	sb.WriteString(ufmt.Sprintf("**Status:** %s\n", app.Status))
	sb.WriteString(ufmt.Sprintf("**Deposit:** %s GNOT\n", formatGNOT(app.Deposit)))
	sb.WriteString(ufmt.Sprintf("**Applied at block:** %d\n", app.AppliedAt))
	sb.WriteString(ufmt.Sprintf("**Attempt #:** %d\n\n", app.ApplyCount))
	sb.WriteString("## Bio\n\n")
	sb.WriteString(sanitizeForRender(app.Bio) + "\n\n")
	sb.WriteString("## Skills\n\n")
	sb.WriteString(sanitizeForRender(app.Skills) + "\n")

	return sb.String()
}

// ── Helpers ──────────────────────────────────────────────────

// sanitizeForRender strips markdown-sensitive characters to prevent injection.
func sanitizeForRender(s string) string {
	var out strings.Builder
	for _, c := range s {
		switch c {
		case '[', ']', '(', ')', '#', '*', '`', '!', '<', '>', '|', '\\', '_', '~', '\n', '\r', '\t':
			continue
		default:
			out.WriteRune(c)
		}
	}
	return out.String()
}

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

func assertValidAddress(addr address) {
	if addr == "" {
		panic("address cannot be empty")
	}
}

func getApplyCount(addr address) int {
	val, exists := applyCount.Get(addr.String())
	if !exists {
		return 0
	}
	return val.(int)
}

func formatGNOT(ugnot int64) string {
	gnot := ugnot / 1_000_000
	remainder := ugnot % 1_000_000
	if remainder == 0 {
		return strconv.FormatInt(gnot, 10)
	}
	return ufmt.Sprintf("%d.%06d", gnot, remainder)
}
