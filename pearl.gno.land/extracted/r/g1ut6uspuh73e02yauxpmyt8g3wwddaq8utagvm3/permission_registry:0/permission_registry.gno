package permission_registry

import (
	"chain/runtime/unsafe"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// MaxResources bounds total registry state. Raised from the upstream
	// 200 as part of the R1 remediation: with a per-admin quota now
	// carrying the anti-monopoly duty, the global cap is a pure state
	// bound rather than the sole defense against namespace exhaustion.
	MaxResources = 1000

	// MaxResourcesPerAdmin bounds how many resources one address may hold
	// at once. R1 (audit 2026-09-21): the upstream design had only a
	// global cap on a permissionless shared registry, so one unprivileged
	// key could occupy every slot for ~200 cheap transactions and
	// permanently deny the registry to every other tenant. DeleteResource
	// is admin-only, so the squat was irreversible.
	MaxResourcesPerAdmin = 20

	MaxPermissionsPerResource = 50
	MaxHoldersPerPermission   = 200
	MaxNameLen                = 64

	// ReservationPeriod is how long a deleted resource name stays
	// reserved. Finite (re-audit 2026-09-02): eternal tombstones let an
	// attacker cycle create/delete to lock the namespace forever.
	ReservationPeriod = int64(90 * 24 * 3600) // 90 days

	// Render bounds (Y3, audit 2026-09-21). Render walks the whole
	// registry and is reachable by any viewer through gnoweb and
	// vm/qrender, so its cost is borne by third parties rather than by
	// whoever grew the state. Uncapped, the declared limits allowed
	// 1000*50*200 rendered holder entries. The full data stays available
	// through ListResources / GetPermissions / Has, which are bounded per
	// call by construction.
	MaxRenderResources   = 20
	MaxRenderPermissions = 8
	MaxRenderHolders     = 10
)

// Reservation holds a deleted resource name for its former admin AND
// its original creator, and expires.
type Reservation struct {
	Admin   address
	Creator address
	Expires time.Time
}

// resources maps a resource name to the admin address that controls it.
var resources map[string]address

// resourceNames tracks the insertion-ordered list of resource names so
// ListResources can iterate without scanning the map.
var resourceNames []string

// permissions maps resource -> permission -> address -> granted.
// Three-level nesting gives O(1) lookup for Has().
var permissions map[string]map[string]map[address]bool

// permList tracks the ordered list of distinct permission names per
// resource, so GetPermissions can iterate without scanning the full map.
var permList map[string][]string

// retired maps a deleted resource name to its time-bounded
// reservation. Consumers authorize against resource names, so a
// freed name must not be claimable by an attacker while integrators
// may still reference it — but the hold expires so tombstones cannot
// lock the namespace forever.
var retired map[string]*Reservation

// resourceCreators records each resource's ORIGINAL creator,
// immutable through admin transfers, so a hostile admin-transferee
// cannot permanently strand a name against the project that made it.
var resourceCreators map[string]address

// adminResources counts the live resources each address administers, so
// MaxResourcesPerAdmin can be enforced in O(1). Entries are removed when
// the count reaches zero so the map tracks live admins only (R1).
var adminResources map[address]int

// pendingAdmins holds nominated-but-not-yet-accepted admins, keyed by
// resource name. Admin handoff is two-step (Y4): nominating is
// reversible, only the nominee's own acceptance is final.
var pendingAdmins map[string]address

func init() {
	resources = make(map[string]address)
	resourceNames = []string{}
	permissions = make(map[string]map[string]map[address]bool)
	permList = make(map[string][]string)
	retired = make(map[string]*Reservation)
	resourceCreators = make(map[string]address)
	adminResources = make(map[address]int)
	pendingAdmins = make(map[string]address)
}

// mustBeAdmin panics if who is not the admin of the resource.
//
// Y1 (audit 2026-09-21): identity is now passed in from the crossing
// entrypoint's own `cur.Previous().Address()` rather than recomputed by
// a non-crossing helper via unsafe.PreviousRealm(). The stack-walking
// form returned the correct address on every path this realm actually
// exposes, but nothing in the type system tied it to the immediate
// caller — a future non-crossing exported helper calling it would have
// silently resolved its importer's caller instead of its importer
// (security.md Class 2). Threading `cur` makes the binding structural.
func mustBeAdmin(who address, resource string) {
	admin, exists := resources[resource]
	if !exists {
		panic("resource not found: " + resource)
	}
	if who != admin {
		panic("permission denied: caller is not admin of " + resource)
	}
}

// rejectStraySend aborts a transaction that attaches coins. This realm
// has no banker, no payable path and no withdrawal function, so coins
// attached to any entrypoint would be permanently stranded at the realm
// address (Y5, security.md § operational).
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this realm does not accept coins")
	}
}

// releaseAdminSlot decrements an admin's live-resource count, deleting
// the entry when it reaches zero so adminResources never accumulates
// zero-valued keys.
func releaseAdminSlot(a address) {
	adminResources[a]--
	if adminResources[a] <= 0 {
		delete(adminResources, a)
	}
}

// isValidName restricts resource and permission names to lowercase
// alphanumeric with underscores. Beyond hygiene this is a security
// property: names appear in composite trust decisions and rendered
// output, so no delimiter or markdown character may enter one.
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

func nameRuleText(kind string) string {
	return kind + " name must be 1-" + strconv.Itoa(MaxNameLen) +
		" chars, lowercase alphanumeric with underscores only"
}

// ---------- write operations ----------

// CreateResource registers a new named resource. The caller becomes its
// admin and is the only address that can grant or revoke permissions on
// it. A deleted resource name stays reserved for its former admin and
// its original creator until the reservation expires.
//
// Each address may administer at most MaxResourcesPerAdmin resources at
// once, and the registry holds at most MaxResources in total.
func CreateResource(cur realm, resourceName string) {
	rejectStraySend(cur)
	who := cur.Previous().Address()

	if !isValidName(resourceName) {
		panic(nameRuleText("resource"))
	}
	if _, exists := resources[resourceName]; exists {
		panic("resource already exists: " + resourceName)
	}

	creator := who
	if res, wasRetired := retired[resourceName]; wasRetired {
		if time.Now().After(res.Expires) {
			// The hold lapsed: drop the tombstone now rather than leaving
			// it for the success path below, so a lapsed reservation is
			// reclaimed even if this call goes on to abort.
			delete(retired, resourceName)
		} else {
			if who != res.Admin && who != res.Creator {
				panic("resource name is reserved for its former admin: " + resourceName)
			}
			// round-3 audit: an in-window re-create must PRESERVE the
			// original creator — otherwise a hostile admin-transferee could
			// delete and instantly re-create, erasing the original project's
			// reclaim right for every future cycle
			if res.Creator != "" {
				creator = res.Creator
			}
		}
	}
	if len(resources) >= MaxResources {
		panic("global resource limit reached")
	}
	if adminResources[who] >= MaxResourcesPerAdmin {
		panic("per-admin resource limit reached")
	}

	resources[resourceName] = who
	adminResources[who]++
	resourceCreators[resourceName] = creator
	resourceNames = append(resourceNames, resourceName)
	permissions[resourceName] = make(map[string]map[address]bool)
	permList[resourceName] = []string{}
	delete(retired, resourceName)
}

// DeleteResource removes a resource and every permission under it. Only
// the resource admin can call this. The name stays reserved for the
// caller and for the original creator: nobody else can re-create it and
// inherit its consumers until the reservation expires.
func DeleteResource(cur realm, resourceName string) {
	rejectStraySend(cur)
	who := cur.Previous().Address()
	mustBeAdmin(who, resourceName)

	retired[resourceName] = &Reservation{
		Admin:   who,
		Creator: resourceCreators[resourceName],
		Expires: time.Now().Add(time.Duration(ReservationPeriod) * time.Second),
	}
	releaseAdminSlot(who)
	delete(resources, resourceName)
	delete(resourceCreators, resourceName)
	delete(permissions, resourceName)
	delete(permList, resourceName)
	// a nomination cannot outlive the resource it was made against
	delete(pendingAdmins, resourceName)
	for i, n := range resourceNames {
		if n == resourceName {
			resourceNames = append(resourceNames[:i], resourceNames[i+1:]...)
			break
		}
	}
}

// Grant gives an address a named permission on a resource. Only the
// resource admin can call this. Panics if the permission is already
// granted to avoid silent no-ops.
func Grant(cur realm, resourceName, permission string, addr address) {
	rejectStraySend(cur)
	mustBeAdmin(cur.Previous().Address(), resourceName)
	if !isValidName(permission) {
		panic(nameRuleText("permission"))
	}
	if addr == "" || !addr.IsValid() {
		panic("invalid address: " + string(addr))
	}

	perms := permissions[resourceName]
	if perms[permission] == nil {
		if len(permList[resourceName]) >= MaxPermissionsPerResource {
			panic("permission limit reached for resource " + resourceName)
		}
		perms[permission] = make(map[address]bool)
		permList[resourceName] = append(permList[resourceName], permission)
	}

	if perms[permission][addr] {
		panic("permission already granted: " + permission + " to " + string(addr))
	}
	if len(perms[permission]) >= MaxHoldersPerPermission {
		panic("holder limit reached for permission " + permission)
	}
	perms[permission][addr] = true
}

// Revoke removes a permission from an address. Only the resource admin
// can call this. Panics if the permission was not granted. A permission
// left with no holders is pruned from the resource's permission list.
func Revoke(cur realm, resourceName, permission string, addr address) {
	rejectStraySend(cur)
	mustBeAdmin(cur.Previous().Address(), resourceName)

	perms := permissions[resourceName]
	if perms[permission] == nil || !perms[permission][addr] {
		panic("permission not granted: " + permission + " to " + string(addr))
	}
	delete(perms[permission], addr)

	if len(perms[permission]) == 0 {
		delete(perms, permission)
		for i, p := range permList[resourceName] {
			if p == permission {
				permList[resourceName] = append(permList[resourceName][:i], permList[resourceName][i+1:]...)
				break
			}
		}
	}
}

// TransferAdmin nominates a new admin for a resource. Only the current
// admin can call this, and the handoff does NOT take effect until the
// nominee calls AcceptAdmin.
//
// Y4 (audit 2026-09-21): the upstream one-step transfer made a
// well-formed-but-unowned destination permanently fatal. address.IsValid
// only checks bech32 form, so a mistyped address passed the check and
// left the resource with an admin nobody controls — it could never again
// be granted on, revoked from, transferred or deleted, and its slot was
// lost from both the global cap and the former admin's quota forever.
// Nomination is reversible; only the nominee's consent is final.
func TransferAdmin(cur realm, resourceName string, newAdmin address) {
	rejectStraySend(cur)
	who := cur.Previous().Address()
	mustBeAdmin(who, resourceName)
	if newAdmin == "" || !newAdmin.IsValid() {
		panic("invalid new admin address: " + string(newAdmin))
	}
	if newAdmin == who {
		panic("new admin is already the admin of " + resourceName)
	}
	pendingAdmins[resourceName] = newAdmin
}

// CancelAdminTransfer withdraws a pending nomination. Only the current
// admin can call this.
func CancelAdminTransfer(cur realm, resourceName string) {
	rejectStraySend(cur)
	mustBeAdmin(cur.Previous().Address(), resourceName)
	if _, ok := pendingAdmins[resourceName]; !ok {
		panic("no pending admin transfer for " + resourceName)
	}
	delete(pendingAdmins, resourceName)
}

// AcceptAdmin completes a pending handoff; only the nominee may call it.
// The nominee's quota is checked HERE — at consent time — so a
// nomination can never push an account past MaxResourcesPerAdmin without
// that account agreeing to carry the resource.
func AcceptAdmin(cur realm, resourceName string) {
	rejectStraySend(cur)
	who := cur.Previous().Address()

	nominee, pending := pendingAdmins[resourceName]
	if !pending {
		panic("no pending admin transfer for " + resourceName)
	}
	if who != nominee {
		panic("caller is not the pending admin of " + resourceName)
	}
	former, exists := resources[resourceName]
	if !exists {
		panic("resource not found: " + resourceName)
	}
	if adminResources[who] >= MaxResourcesPerAdmin {
		panic("accepting would exceed the per-admin resource limit")
	}

	releaseAdminSlot(former)
	adminResources[who]++
	resources[resourceName] = who
	delete(pendingAdmins, resourceName)
}

// ---------- read-only queries ----------

// Has returns true if addr holds the named permission on the resource.
// Returns false (never panics) for unknown resources or permissions.
//
// INTEGRATOR CONTRACT (Y7): Has takes the subject address explicitly and
// performs NO caller authentication — it answers "does this address hold
// this permission", not "may my caller do this". A consuming realm must
// derive addr from its own crossing entrypoint's cur.Previous().Address()
// and pass it in. Deriving it inside a non-crossing helper via
// unsafe.PreviousRealm() resolves the consumer's own caller's caller and
// is a Class-2 designation-forgery bug in the consumer.
func Has(resourceName, permission string, addr address) bool {
	perms, exists := permissions[resourceName]
	if !exists {
		return false
	}
	holders := perms[permission]
	if holders == nil {
		return false
	}
	return holders[addr]
}

// GetPermissions returns all permission names granted to addr on a
// resource, as a comma-separated string. Returns "none" if the address
// has no permissions.
func GetPermissions(resourceName string, addr address) string {
	perms, exists := permissions[resourceName]
	if !exists {
		return "none"
	}

	var result []string
	for _, perm := range permList[resourceName] {
		holders := perms[perm]
		if holders != nil && holders[addr] {
			result = append(result, perm)
		}
	}
	if len(result) == 0 {
		return "none"
	}
	return strings.Join(result, ", ")
}

// ListResources returns all registered resource names as a comma-separated
// string in registration order. Returns "none" if no resources exist.
func ListResources() string {
	if len(resourceNames) == 0 {
		return "none"
	}
	return strings.Join(resourceNames, ", ")
}

// GetAdmin returns the admin address of a resource.
func GetAdmin(resourceName string) string {
	admin, exists := resources[resourceName]
	if !exists {
		return "not found"
	}
	return string(admin)
}

// GetPendingAdmin returns the nominated admin awaiting acceptance for a
// resource, or "none".
func GetPendingAdmin(resourceName string) string {
	a, ok := pendingAdmins[resourceName]
	if !ok {
		return "none"
	}
	return string(a)
}

// ---------- render ----------

// Render returns a markdown overview. Never panics. Output is bounded
// by MaxRenderResources / MaxRenderPermissions / MaxRenderHolders (Y3);
// truncated sections name the query to use for complete data.
func Render(path string) string {
	if resources == nil || len(resourceNames) == 0 {
		return "# Permission Registry\n\nNo resources registered.\n"
	}

	var b strings.Builder
	b.WriteString("# Permission Registry\n\n")
	b.WriteString("Registered resources: " + strconv.Itoa(len(resourceNames)) + "\n\n")

	shown := len(resourceNames)
	if shown > MaxRenderResources {
		shown = MaxRenderResources
	}

	for _, name := range resourceNames[:shown] {
		admin := resources[name]
		b.WriteString("## " + name + "\n\n")
		b.WriteString("**Admin:** `" + string(admin) + "`\n\n")
		if p, ok := pendingAdmins[name]; ok {
			b.WriteString("**Pending admin:** `" + string(p) + "` (awaiting acceptance)\n\n")
		}

		perms, exists := permissions[name]
		if !exists || len(perms) == 0 {
			b.WriteString("_No permissions defined._\n\n")
			continue
		}

		names := permList[name]
		pShown := len(names)
		if pShown > MaxRenderPermissions {
			pShown = MaxRenderPermissions
		}

		b.WriteString("| Permission | Addresses |\n")
		b.WriteString("|------------|-----------|\n")

		for _, perm := range names[:pShown] {
			holders := perms[perm]
			if holders == nil || len(holders) == 0 {
				continue
			}
			var addrs []string
			for addr := range holders {
				if holders[addr] {
					addrs = append(addrs, string(addr))
				}
			}
			// sort the FULL holder set before truncating, so the subset
			// shown is a deterministic function of state rather than of
			// map layout
			sort.Strings(addrs)
			extra := 0
			if len(addrs) > MaxRenderHolders {
				extra = len(addrs) - MaxRenderHolders
				addrs = addrs[:MaxRenderHolders]
			}
			for i, a := range addrs {
				addrs[i] = "`" + a + "`"
			}
			cell := strings.Join(addrs, ", ")
			if extra > 0 {
				cell += ", … +" + strconv.Itoa(extra) + " more"
			}
			b.WriteString("| " + perm + " | " + cell + " |\n")
		}
		if len(names) > pShown {
			b.WriteString("\n_… " + strconv.Itoa(len(names)-pShown) +
				" more permission(s) on this resource. Use GetPermissions or Has for complete data._\n")
		}
		b.WriteString("\n")
	}

	if len(resourceNames) > shown {
		b.WriteString("_… " + strconv.Itoa(len(resourceNames)-shown) +
			" more resource(s) not shown. Use ListResources, GetPermissions or Has for complete data._\n")
	}

	return b.String()
}
