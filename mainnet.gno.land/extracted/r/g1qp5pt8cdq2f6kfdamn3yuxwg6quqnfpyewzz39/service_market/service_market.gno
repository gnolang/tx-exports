// Realm service_market is a custodial GNOT marketplace for SERVICES:
// providers publish a standing offer (title, description, price,
// delivery window), a customer purchases it by paying the exact price
// into escrow, the provider marks the work delivered, and the escrow is
// released to the provider only once the customer accepts — or once the
// acceptance window lapses.
//
// COMPOSITION (per the recorded DISCOVERY / REUSE ANALYSIS in
// DISCOVERY.md): balance accounting is feeledger, coin movement is
// coinio, free-text render safety is p/nt/markdown/sanitize/v0. This
// realm owns only the two-level offer/order state machine, which the
// discovery gate found nowhere else: every escrow realm in the searched
// sources escrows FUNDER-FIRST (the party who will later decide escrows
// first, then solicits work), while a service marketplace must escrow
// CUSTOMER-FIRST against a standing offer.
//
// LIFECYCLE. A service is a reusable offer; an order is one purchase of
// it. Order terminal states are frozen and reached exactly once.
//
//	RegisterService (anyone, no coins) : status Active. The fee bps is
//	                                     SNAPSHOTTED under the
//	                                     provider's own maxFeeBps
//	                                     ceiling.
//	RetireService (provider only)      : Active -> Retired. Blocks NEW
//	                                     orders only; orders already in
//	                                     flight are untouched.
//	PurchaseService (EOA + -send)      : order Purchased, amount into
//	                                     escrow. Sets the delivery
//	                                     deadline.
//	MarkDelivered (provider only)      : Purchased -> Delivered. Starts
//	                                     the acceptance window.
//	AcceptDelivery (customer only)     : Delivered -> Released. THE
//	                                     RESOLUTION. Escrow becomes the
//	                                     provider's claimable balance
//	                                     minus the snapshotted fee.
//	ReleaseTimeout (anyone)            : Delivered -> Released after
//	                                     AcceptanceBlocks. Deemed
//	                                     acceptance.
//	DeclineOrder (provider only)       : Purchased -> Refunded, fee-free.
//	ClaimRefund (anyone)               : Purchased -> Refunded after the
//	                                     delivery deadline, fee-free.
//	Claim / ClaimAll (anyone)          : pays out the caller's own
//	                                     claimable balance.
//
// EVERY VALUE EXIT IS A PULL. Release and refund only move numbers
// between the escrow pool and a claimable balance; the beneficiary
// later calls Claim. Nothing in this realm ever pushes coins to a third
// party, which is what lets both timeout valves stay permissionless: a
// stranger triggering ReleaseTimeout or ClaimRefund performs no send, so
// a beneficiary that cannot receive a send can never brick the valve.
//
// THE THREE REQUIRED PROTECTIONS.
//
// Unauthorized settlement: every identity derives from the crossing
// entrypoint's cur.Previous().Address(); no function takes a caller
// identity as a parameter (the designation-forgery shape that
// disqualified most of the escrow realms found in discovery). The payee
// is COPIED INTO THE ORDER at purchase, so neither retiring the service
// nor any later edit can redirect an in-flight order's payment. There is
// no admin path to any order's escrow: the admin sets the fee for FUTURE
// registrations and nothing else.
//
// Double payment: an order's status is checked and driven terminal in
// the same transaction that moves its value, and escrowTotal is
// decremented in lockstep with the credit. Release and refund both
// require a non-terminal status, so at most one of them can ever
// succeed for a given order, and neither can succeed twice.
//
// Stuck funds: both counterparties have a permissionless valve against
// the other's inaction. A provider who never delivers loses the escrow
// back to the customer at the delivery deadline (ClaimRefund); a
// customer who never accepts loses it to the provider at the acceptance
// deadline (ReleaseTimeout). Neither valve trusts its caller.
//
// ACCEPTANCE IS A PROTOCOL CONSTANT, NOT A PROVIDER SETTING. The
// provider chooses the delivery window (their own commitment, and their
// own risk), but AcceptanceBlocks is fixed. Were it provider-chosen, a
// provider would set it to zero, mark work delivered, and auto-release
// in the same block — settlement without resolution, wearing the
// costume of a timeout.
//
// MONETARY INVARIANT (conservation). With H = ugnot held at the realm
// address, E = escrowTotal (Σ amount over Purchased and Delivered
// orders), U = claimable balances, F = the fee pot, S >= 0 out-of-band
// surplus:
//
//	H == E + U + F + S
//
// PurchaseService raises H and E by exactly the price. Release moves
// amount from E to U+F (feeledger guarantees credited + fee == amount);
// refund moves amount from E to U at zero fee. Claim*/WithdrawFees debit
// the ledger before coinio.Payout moves the identical amount out. Any
// panic aborts the whole transaction; this realm never issues or removes
// coins. Surplus is recoverable only via SweepDenom (fee recipient),
// which reserves Liabilities() = E + U + F.
//
// LIMITATION — NO DISPUTE ARBITRATION, DELIBERATELY. This realm resolves
// on acceptance or on the acceptance timeout. It does NOT adjudicate
// whether delivered work was good. A customer who considers the work
// inadequate has no lever here beyond declining to accept, and the
// timeout will still pay the provider. That is a real limitation and it
// is the deliberate price of the property above: an arbiter empowered to
// redirect escrow is a party who can seize funds, and the closest realm
// found in discovery (r/samcrew/escrow_v3) carries exactly that shape —
// a single hardcoded admin key, with no rotation function, that is
// simultaneously sole arbiter, a unilateral release path, and a
// permanent pause switch over every fund path. Adding arbitration here
// would change what this application IS and expand its security model,
// so it is refused rather than smuggled in. A deployment that needs
// adjudicated disputes needs that designed, audited and authorized as
// its own application.
//
// REALM-CALLER CAVEAT: assertNoSend reads the ORIGIN transaction's send
// envelope, not this realm's receipt, so a realm caller is refused by
// every non-payable function whenever the SAME transaction attached a
// -send anywhere — even though this realm received nothing. It fails
// closed, it is not third-party triggerable, and the workaround is to
// isolate the call in its own -send-free transaction.
//
// Named concretely, because the generic phrasing understates where it
// lands. It applies to every exported function except PurchaseService,
// the only payable one, but four of them carry the weight:
// MarkDelivered, without which no order against a realm provider can
// ever reach a release; ReleaseTimeout and ClaimRefund, the two valves
// this design deliberately leaves permissionless; and Claim / ClaimAll,
// the only paths that extract a credited balance. A realm-based keeper
// bot that batches a valve call into a transaction carrying coins for
// some other purpose is therefore silently unusable, and a realm
// provider must budget a dedicated transaction both to deliver and to
// collect.
// Requirement 3 (no stuck funds) survives this: both valves are
// permissionless and any EOA can pull them, so no order depends on a
// realm caller to unstick.
package service_market

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/coinio"
	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// AcceptanceBlocks is how long a customer has to accept a delivery
// before anyone may release it to the provider. It is a PROTOCOL
// constant on purpose — see the header. ~7 days at pearl's observed
// ~4.2s blocks.
const AcceptanceBlocks = int64(140000)

// Service status values.
const (
	ServiceActive  = "active"
	ServiceRetired = "retired"
)

// Order status values. Released and Refunded are terminal.
const (
	OrderPurchased = "purchased"
	OrderDelivered = "delivered"
	OrderReleased  = "released"
	OrderRefunded  = "refunded"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxDescLen  = 2000
	MaxURILen   = 400
	MinPrice    = int64(1)

	// MinDeliveryBlocks/MaxDeliveryBlocks bound the provider's own
	// turnaround commitment: ~1 hour to ~60 days.
	MinDeliveryBlocks = int64(850)
	MaxDeliveryBlocks = int64(1200000)

	// MaxServicesPerProvider bounds catalog monopolization by a single
	// address. The same finding was RED in both permission_registry and
	// service_registry; it is cheaper to carry the counter from the
	// start than to discover it in an audit.
	MaxServicesPerProvider = 20

	// RenderLimit bounds the home page. An unbounded Render was YELLOW
	// in three prior audits.
	RenderLimit = 20
)

type service struct {
	id             int64
	provider       address
	title          string
	description    string
	price          int64
	deliveryBlocks int64
	feeBps         int64 // snapshotted at registration, charged at release
	status         string
	orders         int64 // lifetime count, never decremented
}

type order struct {
	id        int64
	serviceID int64
	customer  address
	provider  address // copied at purchase; never re-read from the service
	amount    int64
	feeBps    int64 // copied at purchase from the service's snapshot
	status    string

	deliveryDeadline   int64 // absolute height; meaningful while Purchased
	acceptanceDeadline int64 // absolute height; set at MarkDelivered
	deliveryURI        string
}

var (
	admin        address // may set fee, fee recipient, stage successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW services

	self        address // this realm's address, captured at deploy
	nextService int64
	nextOrder   int64
	escrowTotal int64 // == Σ amount over Purchased and Delivered orders

	services    = avl.NewTree() // padID(id)   -> *service
	orders      = avl.NewTree() // padID(id)   -> *order
	providerNum = avl.NewTree() // address     -> *int64, services per provider
	ledger      = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- provider side ---

// RegisterService publishes a standing offer and returns its id. No
// coins are accepted; the storage deposit the caller pays is the
// anti-spam. The current protocol fee is snapshotted into the service
// and must not exceed maxFeeBps, the ceiling the provider signed for —
// pass MaxFeeBps to accept any legal fee.
//
// Providers may be EOAs or realms, but a realm provider takes on three
// obligations that this realm cannot check for it. Realm bytes are
// immutable after addpkg, so a realm deployed without them cannot
// acquire them later: failing (1) means it never earns, failing (2) or
// (3) means what it earned is permanently stranded.
//
//  1. It must already expose a crossing entrypoint that calls
//     MarkDelivered. That is the only transition to OrderDelivered, and
//     both release paths require it, so a provider realm that cannot
//     call it never earns a credit at all — every order against it runs
//     to ClaimRefund instead. This obligation binds before the next one.
//  2. It must already expose a crossing entrypoint that calls Claim or
//     ClaimAll on this realm. A credited balance is a pull, never a
//     push; nothing here can reach into a provider realm to deliver it.
//  3. It must make both calls in transactions whose ORIGIN carried no
//     -send, per the REALM-CALLER CAVEAT in the package header.
//
// The customer side is not symmetric: PurchaseService is payable and
// routes through coinio.Receive, which requires an EOA calling directly
// via MsgCall. A realm can therefore sell a service here but cannot buy
// one — and "can sell" is exactly as strong as the three obligations
// above, no stronger. A customer is structurally always an EOA, which
// is why the permissionless valves are always pullable.
func RegisterService(cur realm, title, description string, price, deliveryBlocks, maxFeeBps int64) int64 {
	assertNoSend()
	provider := cur.Previous().Address()

	assertValidTitle(title)
	if len(description) > MaxDescLen {
		panic("description must be at most " + strconv.Itoa(MaxDescLen) + " characters")
	}
	if price < MinPrice {
		panic("price must be at least " + itoa(MinPrice) + Denom)
	}
	if deliveryBlocks < MinDeliveryBlocks || deliveryBlocks > MaxDeliveryBlocks {
		panic("deliveryBlocks must be " + itoa(MinDeliveryBlocks) + "-" + itoa(MaxDeliveryBlocks))
	}
	if maxFeeBps < 0 || maxFeeBps > MaxFeeBps {
		panic("maxFeeBps must be 0-" + itoa(MaxFeeBps))
	}
	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds your ceiling of " + itoa(maxFeeBps) + " bps")
	}
	if countFor(provider) >= MaxServicesPerProvider {
		panic("at most " + strconv.Itoa(MaxServicesPerProvider) + " services per provider")
	}

	id := nextService
	nextService++
	services.Set(padID(id), &service{
		id:             id,
		provider:       provider,
		title:          title,
		description:    description,
		price:          price,
		deliveryBlocks: deliveryBlocks,
		feeBps:         feeBps,
		status:         ServiceActive,
	})
	bumpFor(provider, 1)

	chain.Emit("ServiceRegistered",
		"id", itoa(id),
		"provider", provider.String(),
		"price", itoa(price),
		"feeBps", itoa(feeBps),
	)
	return id
}

// RetireService stops a service accepting NEW orders. Orders already in
// flight keep their own copies of provider, amount and fee, and run to
// their own terminal states unaffected. Provider only, and terminal —
// there is no un-retire, so a customer reading "active" cannot have it
// flicker underneath them.
func RetireService(cur realm, id int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	s := mustGetService(id)
	if caller != s.provider {
		panic("only the provider may retire this service")
	}
	if s.status != ServiceActive {
		panic("service is not active")
	}
	s.status = ServiceRetired
	bumpFor(s.provider, -1)

	chain.Emit("ServiceRetired", "id", itoa(id), "provider", s.provider.String())
}

// --- customer side ---

// PurchaseService escrows EXACTLY the listed price and opens an order.
// The caller must be an EOA (coinio.Receive is the receipt-guaranteed
// shape) and must attach exactly the price in ugnot; any mismatch aborts
// and the coins revert with the transaction. Self-purchase is rejected.
func PurchaseService(cur realm, serviceID int64) int64 {
	customer, amount := coinio.Receive(0, cur, Denom)
	s := mustGetService(serviceID)
	if s.status != ServiceActive {
		panic("service is not active")
	}
	if customer == s.provider {
		panic("the provider cannot purchase their own service")
	}
	if amount != s.price {
		panic("send exactly the listed price: " + itoa(s.price) + Denom)
	}

	newEscrow, ok := checkedAdd(escrowTotal, amount)
	if !ok {
		panic("escrow total would overflow")
	}

	id := nextOrder
	nextOrder++
	orders.Set(padID(id), &order{
		id:               id,
		serviceID:        serviceID,
		customer:         customer,
		provider:         s.provider,
		amount:           amount,
		feeBps:           s.feeBps,
		status:           OrderPurchased,
		deliveryDeadline: runtime.ChainHeight() + s.deliveryBlocks,
	})
	escrowTotal = newEscrow
	s.orders++

	chain.Emit("ServicePurchased",
		"orderId", itoa(id),
		"serviceId", itoa(serviceID),
		"customer", customer.String(),
		"provider", s.provider.String(),
		"amount", itoa(amount),
	)
	return id
}

// MarkDelivered records that the work is done and starts the acceptance
// window. Provider only. The uri is an opaque reference to the
// deliverable; this realm neither fetches nor interprets it, and it is
// sanitized on the way out to Render.
//
// Delivering AFTER the delivery deadline is allowed as long as nobody
// has yet called ClaimRefund — late work the customer still wants should
// not be destroyed by a deadline that exists to protect the customer.
// The customer's remedy is unchanged: they simply do not accept, and the
// refund valve stays open right up until this transition lands.
func MarkDelivered(cur realm, orderID int64, uri string) {
	assertNoSend()
	caller := cur.Previous().Address()
	o := mustGetOrder(orderID)
	if caller != o.provider {
		panic("only the provider may mark this order delivered")
	}
	if o.status != OrderPurchased {
		panic("order is not awaiting delivery")
	}
	if len(uri) > MaxURILen {
		panic("uri must be at most " + strconv.Itoa(MaxURILen) + " characters")
	}

	o.status = OrderDelivered
	o.deliveryURI = uri
	o.acceptanceDeadline = runtime.ChainHeight() + AcceptanceBlocks

	chain.Emit("OrderDelivered",
		"orderId", itoa(orderID),
		"provider", o.provider.String(),
		"acceptanceDeadline", itoa(o.acceptanceDeadline),
	)
}

// AcceptDelivery is THE RESOLUTION: the customer accepts the delivered
// work and the escrow becomes the provider's claimable balance, minus
// the fee snapshotted into the order at purchase. Customer only.
func AcceptDelivery(cur realm, orderID int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	o := mustGetOrder(orderID)
	if caller != o.customer {
		panic("only the customer may accept this delivery")
	}
	if o.status != OrderDelivered {
		panic("order is not awaiting acceptance")
	}
	release(o, "accepted")
}

// ReleaseTimeout releases a delivered order to the provider once the
// acceptance window has lapsed. Permissionless: a customer who stops
// responding must not be able to strand a provider's completed work.
// This is deemed acceptance, and it is the only path by which escrow
// reaches a provider without the customer's explicit act.
func ReleaseTimeout(cur realm, orderID int64) {
	assertNoSend()
	o := mustGetOrder(orderID)
	if o.status != OrderDelivered {
		panic("order is not awaiting acceptance")
	}
	if runtime.ChainHeight() < o.acceptanceDeadline {
		panic("acceptance window has not lapsed: " +
			itoa(o.acceptanceDeadline-runtime.ChainHeight()) + " blocks remain")
	}
	release(o, "timeout")
}

// DeclineOrder returns the escrow to the customer before delivery.
// Provider only, fee-free — a provider who cannot fulfil should be able
// to hand the money straight back rather than wait out a deadline. Safe
// to allow unilaterally because it only ever moves value AWAY from the
// caller.
func DeclineOrder(cur realm, orderID int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	o := mustGetOrder(orderID)
	if caller != o.provider {
		panic("only the provider may decline this order")
	}
	if o.status != OrderPurchased {
		panic("order is not awaiting delivery")
	}
	refund(o, "declined")
}

// ClaimRefund returns the escrow to the customer once the provider has
// missed the delivery deadline. Permissionless: a provider who abandons
// an order must not be able to strand the customer's money.
//
// It is fee-free. Charging a protocol fee on a refund would mean the
// marketplace profits from provider non-performance.
func ClaimRefund(cur realm, orderID int64) {
	assertNoSend()
	o := mustGetOrder(orderID)
	if o.status != OrderPurchased {
		panic("order is not awaiting delivery")
	}
	if runtime.ChainHeight() < o.deliveryDeadline {
		panic("delivery window has not lapsed: " +
			itoa(o.deliveryDeadline-runtime.ChainHeight()) + " blocks remain")
	}
	refund(o, "expired")
}

// --- payouts ---

// Claim sends amount ugnot of the caller's claimable balance back to the
// caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance back to the
// caller. Fails if there is nothing to claim.
func ClaimAll(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the
// fee recipient may call it.
func WithdrawFees(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may withdraw fees")
	}
	if ledger.FeesAccrued() == 0 {
		panic("no fees accrued")
	}
	amount := ledger.WithdrawFees()
	coinio.Payout(0, cur, feeRecipient, Denom, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient. For ugnot only the excess over Liabilities() moves — which
// reserves live escrow as well as claimable balances and the fee pot —
// and other denoms move wholly. Only the fee recipient may call it.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

// --- administration ---

// SetFeeBps sets the protocol fee snapshotted into FUTURE services.
// Existing services, and every order already placed against them, keep
// the fee they were created under. Admin only; bounded by [0, MaxFeeBps].
func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be 0-" + itoa(MaxFeeBps) + " bps")
	}
	feeBps = bps
	chain.Emit("FeeChanged", "bps", itoa(bps))
}

// SetFeeRecipient sets the address that may withdraw fees and sweep
// surplus. Admin only.
func SetFeeRecipient(cur realm, next address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if !next.IsValid() {
		panic("invalid fee recipient address")
	}
	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "to", next.String())
}

// TransferAdmin stages a successor. Two-step: the successor must call
// AcceptAdmin, so a typo cannot orphan the realm. Admin only. Passing
// the zero address cancels a pending nomination; any other value must be
// a well-formed address, for parity with SetFeeRecipient. The two-step
// handover already made a malformed nominee harmless — it could never
// call AcceptAdmin — so this check rejects the typo at the point it is
// made rather than leaving it staged and readable as a real nomination.
func TransferAdmin(cur realm, next address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if next != "" && !next.IsValid() {
		panic("invalid admin address")
	}
	pendingAdmin = next
	chain.Emit("AdminNominated", "to", next.String())
}

// AcceptAdmin completes a staged handover. Only the nominee may call it.
func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("only the nominated admin may accept")
	}
	admin = caller
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "to", admin.String())
}

// --- views ---

func ServiceInfo(id int64) (provider address, title string, price, deliveryBlocks, feeBps int64, status string, orderCount int64) {
	s := mustGetService(id)
	return s.provider, s.title, s.price, s.deliveryBlocks, s.feeBps, s.status, s.orders
}

func ServiceDescription(id int64) string { return mustGetService(id).description }

func OrderInfo(id int64) (serviceID int64, customer, provider address, amount, feeBps int64, status string) {
	o := mustGetOrder(id)
	return o.serviceID, o.customer, o.provider, o.amount, o.feeBps, o.status
}

// OrderDeadlines returns the two absolute heights that govern an order.
// acceptanceDeadline is 0 until the order is delivered.
func OrderDeadlines(id int64) (deliveryDeadline, acceptanceDeadline int64) {
	o := mustGetOrder(id)
	return o.deliveryDeadline, o.acceptanceDeadline
}

func OrderURI(id int64) string { return mustGetOrder(id).deliveryURI }

// Quote reports what a purchase of this service would cost and what the
// provider would receive on resolution, at the service's snapshotted fee.
func Quote(id int64) (price, fee, toProvider int64) {
	s := mustGetService(id)
	f, err := feeledger.FeeFor(s.price, s.feeBps)
	if err != nil {
		panic(err)
	}
	return s.price, f, s.price - f
}

func Admin() address             { return admin }
func PendingAdmin() address      { return pendingAdmin }
func FeeRecipient() address      { return feeRecipient }
func FeeBps() int64              { return feeBps }
func NumServices() int64         { return nextService }
func NumOrders() int64           { return nextOrder }
func ServicesOf(a address) int64 { return countFor(a) }

func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }
func UsersTotal() int64            { return ledger.UsersTotal() }
func FeesAccrued() int64           { return ledger.FeesAccrued() }

// EscrowTotal is the live escrow pool E: the sum of every order still in
// Purchased or Delivered.
func EscrowTotal() int64 { return escrowTotal }

// Liabilities is everything this realm owes: live escrow, claimable
// balances and the fee pot. SweepDenom reserves exactly this.
func Liabilities() int64 { return escrowTotal + ledger.Liabilities() }

func Held() int64      { return coinio.HeldAt(self, Denom) }
func Surplus() int64   { return Held() - Liabilities() }
func Address() address { return self }
func Height() int64    { return runtime.ChainHeight() }

// --- render ---

func Render(path string) string {
	if len(path) > 2 && path[:2] == "s/" {
		return renderService(path[2:])
	}
	if len(path) > 2 && path[:2] == "o/" {
		return renderOrder(path[2:])
	}
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Service marketplace\n\n"
	out += "Providers publish services; customers purchase into escrow; payment is\n"
	out += "released only on acceptance, or when the acceptance window lapses.\n\n"
	out += "## Configuration\n\n"
	out += "- fee for new services: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) +
		" bps; each service keeps the fee snapshotted at registration)\n"
	out += "- acceptance window: " + itoa(AcceptanceBlocks) + " blocks\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting (H == E + U + F + S)\n\n"
	out += "- escrow held for open orders (E): " + itoa(escrowTotal) + Denom + "\n"
	out += "- claimable balances (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest services\n\n"
	if nextService == 0 {
		out += "No services yet.\n"
		return out
	}
	shown := 0
	services.ReverseIterate("", "", func(_ string, v any) bool {
		s := v.(*service)
		out += "- [#" + itoa(s.id) + "](" + realmPath + ":s/" + itoa(s.id) + ") [" +
			s.status + "] " + s.title + " — " + itoa(s.price) + Denom + "\n"
		shown++
		return shown >= RenderLimit
	})
	return out
}

func renderService(arg string) string {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid service id\n"
	}
	v := services.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown service id\n"
	}
	s := v.(*service)
	out := "# Service #" + itoa(s.id) + ": " + s.title + "\n\n"
	out += "- status: " + s.status + "\n"
	out += "- provider: " + s.provider.String() + "\n"
	out += "- price: " + itoa(s.price) + Denom + "\n"
	out += "- delivery window: " + itoa(s.deliveryBlocks) + " blocks\n"
	out += "- fee (snapshot): " + itoa(s.feeBps) + " bps\n"
	out += "- orders placed: " + itoa(s.orders) + "\n"
	out += "\n## Description\n\n" + sanitize.InlineText(s.description) + "\n"
	return out
}

func renderOrder(arg string) string {
	id, err := strconv.ParseInt(arg, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid order id\n"
	}
	v := orders.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown order id\n"
	}
	o := v.(*order)
	out := "# Order #" + itoa(o.id) + "\n\n"
	out += "- status: " + o.status + "\n"
	out += "- service: [#" + itoa(o.serviceID) + "](" + realmPath + ":s/" + itoa(o.serviceID) + ")\n"
	out += "- customer: " + o.customer.String() + "\n"
	out += "- provider: " + o.provider.String() + "\n"
	out += "- amount: " + itoa(o.amount) + Denom + "\n"
	out += "- fee (snapshot): " + itoa(o.feeBps) + " bps\n"
	out += "- delivery deadline: height " + itoa(o.deliveryDeadline) + "\n"
	if o.acceptanceDeadline != 0 {
		out += "- acceptance deadline: height " + itoa(o.acceptanceDeadline) + "\n"
	}
	if o.deliveryURI != "" {
		out += "\n## Delivery\n\n" + sanitize.InlineText(o.deliveryURI) + "\n"
	}
	return out
}

// --- internals ---

const realmPath = "/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/service_market"

// release moves an order's escrow into the provider's claimable balance
// at the order's snapshotted fee, and drives the order terminal. The
// status write and the escrow decrement happen together with the credit,
// so no order can be released twice and E stays exactly Σ open amounts.
func release(o *order, reason string) {
	credited, fee, err := ledger.Deposit(o.provider.String(), o.amount, o.feeBps)
	if err != nil {
		panic(err)
	}
	o.status = OrderReleased
	escrowTotal -= o.amount // >= 0: escrowTotal == Σ open amounts >= o.amount

	chain.Emit("OrderReleased",
		"orderId", itoa(o.id),
		"provider", o.provider.String(),
		"amount", itoa(o.amount),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"reason", reason,
	)
}

// refund moves an order's escrow into the customer's claimable balance
// at ZERO fee and drives the order terminal.
func refund(o *order, reason string) {
	credited, _, err := ledger.Deposit(o.customer.String(), o.amount, 0)
	if err != nil {
		panic(err)
	}
	o.status = OrderRefunded
	escrowTotal -= o.amount

	chain.Emit("OrderRefunded",
		"orderId", itoa(o.id),
		"customer", o.customer.String(),
		"amount", itoa(credited),
		"reason", reason,
	)
}

// assertNoSend refuses coins on non-payable entrypoints: an accidental
// -send would otherwise strand at the realm as sweep-only surplus.
// PurchaseService is the only payable function. NOTE: this reads the
// ORIGIN envelope — see the realm-provider caveat in the header.
func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this function does not accept coins")
	}
}

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func mustGetService(id int64) *service {
	v := services.Get(padID(id))
	if v == nil {
		panic("unknown service id")
	}
	return v.(*service)
}

func mustGetOrder(id int64) *order {
	v := orders.Get(padID(id))
	if v == nil {
		panic("unknown order id")
	}
	return v.(*order)
}

// countFor reports how many ACTIVE services an address holds.
func countFor(a address) int64 {
	v := providerNum.Get(a.String())
	if v == nil {
		return 0
	}
	return *(v.(*int64))
}

// bumpFor adjusts the active-service counter, removing the entry at zero
// so a provider who retires everything stops paying for the slot.
func bumpFor(a address, delta int64) {
	key := a.String()
	v := providerNum.Get(key)
	if v == nil {
		if delta <= 0 {
			return
		}
		n := delta
		providerNum.Set(key, &n)
		return
	}
	p := v.(*int64)
	*p += delta
	if *p <= 0 {
		providerNum.Remove(key)
	}
}

// assertValidTitle bounds length and restricts the charset so titles are
// list-safe in Render without escaping.
func assertValidTitle(title string) {
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic("title must be 1-" + strconv.Itoa(MaxTitleLen) + " characters")
	}
	for i := 0; i < len(title); i++ {
		c := title[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == ' ' || c == '_' || c == '-':
		default:
			panic("title may only contain letters, digits, space, _ and -")
		}
	}
}

// padID renders an id as a fixed-width key so avl iteration order is
// numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func checkedAdd(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
