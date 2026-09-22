package service_registry

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Service represents a registered on-chain service.
type Service struct {
	Name        string
	Owner       address
	Registrant  address // ORIGINAL registrant; immutable through transfers
	PkgPath     string  // the realm the service lives at — what integrators resolve
	Description string
	ServiceType string // e.g. "token", "dex", "oracle", "dao", "nft", "bridge"
	Metadata    string // freeform key=value pairs or JSON blob
}

// Reservation holds a deregistered name for its former owner AND its
// original registrant, and EXPIRES (re-audit 2026-09-02): an eternal
// reservation let an attacker cycle register/deregister to lock the
// whole namespace forever, and a hostile transferee could strand a
// name against its original registrant permanently.
type Reservation struct {
	Owner      address
	Registrant address
	Expires    time.Time
}

const (
	// MaxServices is a pure state bound, not an anti-squat defense —
	// MaxServicesPerOwner is what makes monopolization expensive
	// (pearl audit R1). Kept at 1000 rather than raised further so the
	// linear scans over `names` (Deregister, ListServices, ListByType)
	// stay bounded at a size one transaction can comfortably pay for.
	MaxServices = 1000

	// MaxServicesPerOwner caps how many names one address may hold at
	// once. Enforced at registration and, for a handoff, at the moment
	// the recipient CONSENTS (see AcceptOwnership).
	MaxServicesPerOwner = 20

	MaxNameLen        = 64
	MaxTypeLen        = 32
	MaxPkgPathLen     = 128
	MaxDescriptionLen = 500
	MaxMetadataLen    = 2000

	pkgPathPrefix = "gno.land/"

	// ReservationPeriod is how long a deregistered name stays reserved.
	// Long enough for integrators to notice the deregistration; finite
	// so tombstones cannot lock the namespace forever.
	ReservationPeriod = int64(90 * 24 * 3600) // 90 days

	// MaxRenderServices bounds the gnoweb table. Render is reachable by
	// any viewer, so its cost lands on third parties rather than on
	// whoever grew the state (pearl audit Y3). Complete data comes from
	// the bounded queries named in the truncation notice.
	MaxRenderServices = 25

	// renderDescLen is the per-row description budget, applied to the
	// RAW text before escaping so an escape sequence is never split.
	renderDescLen = 60
)

var (
	services map[string]*Service
	names    []string // insertion-ordered list for deterministic iteration
	// retired maps a deregistered name to its time-bounded reservation.
	retired map[string]*Reservation
	// ownerServices is the O(1) index backing MaxServicesPerOwner. It is
	// kept zero-free: an owner that drops to zero is deleted outright so
	// the map cannot accumulate dead keys.
	ownerServices map[address]int
	// pendingOwners holds nominated-but-not-yet-accepted owners
	// (pearl audit Y4). A name appears here only while a handoff is open.
	pendingOwners map[string]address
)

func init() {
	services = make(map[string]*Service)
	names = []string{}
	retired = make(map[string]*Reservation)
	ownerServices = make(map[address]int)
	pendingOwners = make(map[string]address)
}

// rejectStraySend aborts when coins are attached to a call (pearl audit
// Y2): this realm handles no funds, holds no banker and exposes no
// withdrawal, so an attached send would strand on the realm address
// forever. Aborting reverts the transfer back to the sender. Fails open
// for realm-routed calls, whose attached send lands on the intermediary
// realm, never here.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this realm does not accept coins")
	}
}

// ---------- quota index ----------

func quotaAdd(owner address) {
	ownerServices[owner] = ownerServices[owner] + 1
}

func quotaDrop(owner address) {
	n := ownerServices[owner] - 1
	if n <= 0 {
		delete(ownerServices, owner)
		return
	}
	ownerServices[owner] = n
}

func assertQuota(owner address) {
	if ownerServices[owner] >= MaxServicesPerOwner {
		panic("address already holds the maximum of " +
			strconv.Itoa(MaxServicesPerOwner) + " services")
	}
}

// ---------- validation helpers ----------

func isValidName(name string) bool {
	if name == "" || len(name) > MaxNameLen {
		return false
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func validatePkgPath(pkgPath string) {
	if pkgPath == "" {
		panic("pkgpath must not be empty")
	}
	if len(pkgPath) > MaxPkgPathLen {
		panic("pkgpath exceeds " + strconv.Itoa(MaxPkgPathLen) + " chars")
	}
	if !strings.HasPrefix(pkgPath, pkgPathPrefix) {
		panic("pkgpath must start with " + pkgPathPrefix + " and name a package")
	}
	// structural, per-element validation (re-audit: the old charset check
	// accepted "..", "//", trailing slashes, hyphens, and non-r/p roots —
	// all lookalike-squat or allowlist-bypass material)
	elems := strings.Split(pkgPath[len(pkgPathPrefix):], "/")
	if len(elems) < 2 || (elems[0] != "r" && elems[0] != "p") {
		panic("pkgpath must be gno.land/r/... or gno.land/p/...")
	}
	for _, e := range elems[1:] {
		if e == "" {
			panic("pkgpath contains an empty element")
		}
		if !(e[0] >= 'a' && e[0] <= 'z') {
			panic("invalid pkgpath element: " + e)
		}
		for _, c := range e {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
				panic("invalid pkgpath element: " + e)
			}
		}
	}
}

func validateFields(description, serviceType, metadata string) {
	if description == "" {
		panic("description must not be empty")
	}
	if len(description) > MaxDescriptionLen {
		panic("description exceeds " + strconv.Itoa(MaxDescriptionLen) + " chars")
	}
	if serviceType == "" {
		panic("service type must not be empty")
	}
	if len(serviceType) > MaxTypeLen || !isValidName(serviceType) {
		panic("service type must be lowercase alphanumeric with underscores, max " +
			strconv.Itoa(MaxTypeLen) + " chars")
	}
	if len(metadata) > MaxMetadataLen {
		panic("metadata exceeds " + strconv.Itoa(MaxMetadataLen) + " chars")
	}
}

// truncate shortens s to at most n runes without splitting a multibyte
// character. Applied to RAW text, never to escaped output — truncating
// after escaping could sever a `\x` pair and leave a dangling backslash.
func truncate(s string, n int) string {
	if n < 4 {
		panic("truncate: budget too small")
	}
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-3]) + "..."
}

func mustGet(name string) *Service {
	svc, ok := services[name]
	if !ok {
		panic("service not found: " + name)
	}
	return svc
}

// ---------- write operations ----------

// RegisterService adds a new service to the registry. The caller becomes
// the owner. Name must be unique, lowercase alphanumeric/underscores.
// pkgPath is the realm the service lives at — the field integrators
// resolve — and must look like a gno.land package path. A name that was
// deregistered stays reserved for its former owner and its original
// registrant for ReservationPeriod.
//
// NOTE: this realm does NOT and cannot verify that pkgPath exists or
// that the caller controls it. See the INTEGRATOR CONTRACT on Resolve.
func RegisterService(cur realm, name, pkgPath, description, serviceType, metadata string) {
	rejectStraySend(cur)
	c := cur.Previous().Address()

	if !isValidName(name) {
		panic("name must be 1-" + strconv.Itoa(MaxNameLen) +
			" chars, lowercase alphanumeric with underscores only")
	}
	validatePkgPath(pkgPath)
	validateFields(description, serviceType, metadata)
	if _, exists := services[name]; exists {
		panic("service already registered: " + name)
	}

	registrant := c
	if res, wasRetired := retired[name]; wasRetired {
		if time.Now().After(res.Expires) {
			// O(1) lazy reclaim: a lapsed tombstone is dropped the moment
			// it is consulted, so the map does not pay to keep entries
			// nobody will ever read again.
			delete(retired, name)
		} else {
			if c != res.Owner && c != res.Registrant {
				panic("name is reserved for its former owner: " + name)
			}
			// round-3 audit: an in-window re-register must PRESERVE the
			// original registrant — otherwise a hostile transferee could
			// deregister and instantly re-register, stamping themselves as
			// registrant and erasing the original project's reclaim right
			if res.Registrant != "" {
				registrant = res.Registrant
			}
		}
	}

	if len(services) >= MaxServices {
		panic("global service limit reached")
	}
	assertQuota(c)

	services[name] = &Service{
		Name:        name,
		Owner:       c,
		Registrant:  registrant,
		PkgPath:     pkgPath,
		Description: description,
		ServiceType: serviceType,
		Metadata:    metadata,
	}
	names = append(names, name)
	quotaAdd(c)
	delete(retired, name)

	chain.Emit("ServiceRegistered",
		"name", name,
		"pkgpath", pkgPath,
		"type", serviceType,
		"owner", c.String(),
		"registrant", registrant.String(),
	)
}

// UpdateService modifies a service's pkgpath, description, type, and
// metadata. Only the registered owner can update. Name cannot change.
//
// An update MAY REPOINT the name at a different package path. That is a
// deliberate capability (services move, and versions supersede), but it
// also means a name an integrator trusts today can point elsewhere
// tomorrow. The ServiceUpdated event carries both the old and the new
// path specifically so a repoint is observable in the transaction log
// rather than something a consumer has to poll for.
func UpdateService(cur realm, name, pkgPath, description, serviceType, metadata string) {
	rejectStraySend(cur)
	svc := mustGet(name)
	if cur.Previous().Address() != svc.Owner {
		panic("only the owner can update this service")
	}
	validatePkgPath(pkgPath)
	validateFields(description, serviceType, metadata)

	oldPath := svc.PkgPath
	svc.PkgPath = pkgPath
	svc.Description = description
	svc.ServiceType = serviceType
	svc.Metadata = metadata

	chain.Emit("ServiceUpdated",
		"name", name,
		"oldpkgpath", oldPath,
		"pkgpath", pkgPath,
		"type", serviceType,
		"owner", svc.Owner.String(),
	)
}

// TransferOwnership NOMINATES a new owner for a service entry; the
// nominee must call AcceptOwnership to take control (pearl audit Y4).
//
// The one-step form this replaces was a permanent-brick hazard:
// address.IsValid() only checks bech32 form, so a well-formed but
// unowned destination passed the check and committed immediately, after
// which the entry could never again be updated, transferred or
// deregistered — and because it could never be deregistered it could
// never enter the reservation window either, so the NAME became a
// permanent hole in a shared global namespace.
//
// Nomination changes nothing: the sitting owner keeps full control
// until the nominee consents. Passing "" clears a pending nomination.
func TransferOwnership(cur realm, name string, newOwner address) {
	rejectStraySend(cur)
	svc := mustGet(name)
	c := cur.Previous().Address()
	if c != svc.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		delete(pendingOwners, name)
		chain.Emit("OwnershipTransferCancelled", "name", name, "owner", c.String())
		return
	}
	if !newOwner.IsValid() {
		panic("invalid new owner address: " + string(newOwner))
	}
	if newOwner == svc.Owner {
		panic("new owner is already the owner")
	}
	pendingOwners[name] = newOwner

	chain.Emit("OwnershipTransferProposed",
		"name", name,
		"owner", c.String(),
		"pending", newOwner.String(),
	)
}

// AcceptOwnership completes a nominated handoff. Only the nominee can
// accept, and the nominee's own quota is checked HERE — at consent —
// so a nomination can never push an account past MaxServicesPerOwner
// without that account agreeing to it.
func AcceptOwnership(cur realm, name string) {
	rejectStraySend(cur)
	svc := mustGet(name)
	c := cur.Previous().Address()

	pending, ok := pendingOwners[name]
	if !ok {
		panic("no pending ownership transfer for: " + name)
	}
	if c != pending {
		panic("only the nominated owner can accept")
	}
	assertQuota(c)

	prev := svc.Owner
	svc.Owner = c
	quotaDrop(prev)
	quotaAdd(c)
	delete(pendingOwners, name)

	chain.Emit("OwnershipTransferred",
		"name", name,
		"from", prev.String(),
		"to", c.String(),
	)
}

// CancelOwnershipTransfer withdraws a pending nomination. Owner-only.
func CancelOwnershipTransfer(cur realm, name string) {
	rejectStraySend(cur)
	svc := mustGet(name)
	c := cur.Previous().Address()
	if c != svc.Owner {
		panic("only the owner can cancel a transfer")
	}
	if _, ok := pendingOwners[name]; !ok {
		panic("no pending ownership transfer for: " + name)
	}
	delete(pendingOwners, name)

	chain.Emit("OwnershipTransferCancelled", "name", name, "owner", c.String())
}

// Deregister removes a service from the registry. Only the owner can
// deregister. The name stays reserved for the former owner and the
// original registrant for ReservationPeriod — it cannot be
// re-registered by anyone else in that window, so integrators who still
// resolve it can never be silently redirected by a squatter.
func Deregister(cur realm, name string) {
	rejectStraySend(cur)
	svc := mustGet(name)
	c := cur.Previous().Address()
	if c != svc.Owner {
		panic("only the owner can deregister")
	}
	retired[name] = &Reservation{
		Owner:      svc.Owner,
		Registrant: svc.Registrant,
		Expires:    time.Now().Add(time.Duration(ReservationPeriod) * time.Second),
	}
	delete(services, name)
	quotaDrop(svc.Owner)
	// a nomination must not outlive the entry it was made against
	delete(pendingOwners, name)

	// Remove from ordered list
	for i, n := range names {
		if n == name {
			names = append(names[:i], names[i+1:]...)
			break
		}
	}

	chain.Emit("ServiceDeregistered",
		"name", name,
		"owner", svc.Owner.String(),
		"registrant", svc.Registrant.String(),
	)
}

// ---------- read-only queries ----------

// Resolve returns the pkgpath a service name points to — the primary
// integration query. Panics on unknown names so a consumer can never
// silently integrate against a missing entry.
//
// INTEGRATOR CONTRACT — read this before trusting a resolution:
//
//  1. A resolution is an ATTESTATION, NOT A PROOF. This realm records
//     that some address claimed a name for some package path. It does
//     NOT verify that the path exists, that it is deployed, or that the
//     registrant controls it. Contrast r/demo/defi/grc20reg, which
//     proves control by requiring the registered token object to
//     originate from the calling realm; no equivalent proof exists for
//     a bare path string, and requiring one would mean only realms —
//     never their operators — could ever register a name, which is not
//     this registry's model.
//
//  2. A NAME IS NOT AN AUTHORIZATION. Never grant a privilege, route a
//     payment, or admit a caller because Resolve returned its path.
//     Resolution answers "where does this name point", never "may this
//     caller act". Derive authority from your own crossing entrypoint's
//     cur.Previous(), or from an explicit access-control realm.
//
//  3. THE TARGET CAN CHANGE. The owner may repoint a name at any time
//     via UpdateService, and ownership itself is transferable. Treat a
//     resolution as valid only for the transaction that read it; cache
//     it and you inherit whatever the name points at later. The
//     ServiceUpdated and OwnershipTransferred events exist so movement
//     is detectable.
func Resolve(name string) string {
	return mustGet(name).PkgPath
}

// TryResolve is the non-panicking variant for consumers that need to
// degrade gracefully when a name disappears (re-audit: a panicking-only
// read path bricks any consumer realm that calls it inline). The
// INTEGRATOR CONTRACT documented on Resolve applies here identically.
func TryResolve(name string) (string, bool) {
	svc, ok := services[name]
	if !ok {
		return "", false
	}
	return svc.PkgPath, true
}

// GetOwner returns the owner address of a service.
func GetOwner(name string) address {
	return mustGet(name).Owner
}

// GetPendingOwner returns the nominated-but-not-yet-accepted owner of a
// service, or "none" when no handoff is open.
func GetPendingOwner(name string) string {
	mustGet(name)
	if p, ok := pendingOwners[name]; ok {
		return p.String()
	}
	return "none"
}

// ServiceCount returns how many services are registered and the global
// cap, so a caller can check headroom without pulling the whole list.
func ServiceCount() (count, limit int) {
	return len(services), MaxServices
}

// OwnerServiceCount returns how many services an address currently holds
// and the per-owner cap.
func OwnerServiceCount(owner address) (count, limit int) {
	return ownerServices[owner], MaxServicesPerOwner
}

// GetService returns a formatted summary of a registered service. Free
// text is escaped for a single-line markdown slot.
func GetService(name string) string {
	svc := mustGet(name)

	var b strings.Builder
	b.WriteString("Name: " + svc.Name + "\n")
	b.WriteString("Owner: " + string(svc.Owner) + "\n")
	b.WriteString("PkgPath: " + svc.PkgPath + "\n")
	b.WriteString("Type: " + svc.ServiceType + "\n")
	b.WriteString("Description: " + sanitize.InlineText(svc.Description) + "\n")
	if svc.Metadata != "" {
		b.WriteString("Metadata: " + sanitize.InlineText(svc.Metadata) + "\n")
	}
	return b.String()
}

// ListServices returns all registered service names as a comma-separated
// string in registration order.
//
// COST NOTE: this is O(MaxServices) and is deliberately NOT truncated —
// an integrator enumerating the registry needs the complete set, and the
// caller pays for its own read. Render, whose cost lands on third-party
// viewers instead, IS bounded.
func ListServices() string {
	if len(names) == 0 {
		return "none"
	}
	return strings.Join(names, ", ")
}

// ListByType returns all service names matching a given type. Same cost
// note as ListServices.
func ListByType(serviceType string) string {
	var result []string
	for _, name := range names {
		svc := services[name]
		if svc != nil && svc.ServiceType == serviceType {
			result = append(result, name)
		}
	}
	if len(result) == 0 {
		return "none"
	}
	return strings.Join(result, ", ")
}

// ---------- render ----------

// Render returns a markdown overview, bounded to MaxRenderServices rows
// (pearl audit Y3). Never panics. All free text goes through the
// ecosystem sanitizer rather than a bespoke escaper: the hand-rolled
// replacement of backticks and pipes it replaces left `[`, `]`, `(`,
// `)` and `!` live, so any registrant could inject a working markdown
// link or image into a table cell and phish every viewer of this page.
func Render(path string) string {
	total := len(services)
	if total == 0 {
		return "# Service Registry\n\nNo services registered.\n"
	}

	var b strings.Builder
	b.WriteString("# Service Registry\n\n")
	b.WriteString("**Total services:** " + strconv.Itoa(total) + "\n\n")

	b.WriteString("| Name | Type | PkgPath | Owner | Description |\n")
	b.WriteString("|------|------|---------|-------|-------------|\n")

	shown := 0
	for _, name := range names {
		if shown >= MaxRenderServices {
			break
		}
		svc := services[name]
		if svc == nil {
			continue
		}
		desc := sanitize.TableCell(truncate(svc.Description, renderDescLen))
		b.WriteString("| " + svc.Name + " | " + svc.ServiceType + " | `" +
			svc.PkgPath + "` | `" + string(svc.Owner) + "` | " + desc + " |\n")
		shown++
	}

	if shown < total {
		b.WriteString("\n_Showing " + strconv.Itoa(shown) + " of " +
			strconv.Itoa(total) + " services. Use ListServices, ListByType " +
			"or GetService for complete data._\n")
	}

	b.WriteString("\n")
	return b.String()
}
