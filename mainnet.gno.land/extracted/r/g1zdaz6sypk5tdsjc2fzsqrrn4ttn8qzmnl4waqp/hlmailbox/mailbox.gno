// Package hlmailbox is the gno.land end of the bridge's message layer (bridge/PLAN.md §5.1): realms send messages to
// other chains through it and take the messages other chains send them from it. Messages, ids and the merkle tree
// are Hyperlane's byte for byte (gno.land/p/…/hyperlane/v0), so the Solana side runs Hyperlane's own programs.
//
// Out. Dispatch takes a message from the realm that calls it, numbers it, puts its id in the merkle tree, keeps the
// message, and emits the Dispatch event the Solana light client proves from LastResultsHash (§13: id, nonce, origin,
// destination, sender, recipient, hash). Reemit emits it again from a fresh block, by anyone.
//
// In. A recipient realm pulls its own messages: it calls Process with the message and the verifier's metadata;
// Process checks the caller is the recipient, that the message is for this chain and was never delivered, marks it
// delivered, and only then asks the active verifier — a realm that registered itself here, chosen by GovDAO by
// pkgpath — whether the message is genuine; a verifier's error is a panic, so the transaction and the mark revert
// together and a refused message stays deliverable.
//
// Who may change what. Nobody holds an admin key: every setting moves by a decision made with this realm's
// builders (gov.gno), at once or after 7 days (§5.3), and nothing but Launch and cancel before the one-shot
// Launch. Who decides is the governor's (M1k): the compiled launchGovernor alone, by its own call through Govern,
// until it yields (Yield, once, for every bridge realm at once), and GovDAO's proposals from then on — or from the
// first block, when no governor was compiled. The guardians and watch keys (flags.gno) can only pause: three flags
// per key per route — sends, credits, payouts — which the routes ask about with Paused. Every launch value is
// compiled in below and written by init.
package hlmailbox

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
)

const (
	namespace = "gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/"
	pkgPath   = namespace + "hlmailbox" // must match gnomod.toml

	// DomainMainnet and DomainTest are gno.land's Hyperlane domain ids, "GnoL" and "GnoT" in ASCII; nobody in the
	// Hyperlane registry holds either (2026-10-10). gnoland-1 is mainnet; every other chain is a test chain.
	DomainMainnet  = uint32(1198419788)
	DomainTest     = uint32(1198419796)
	mainnetChainID = "gnoland-1"

	// SolanaMainnet and SolanaLocal are the destination's domains: Solana's own on mainnet; on any other gno chain
	// the one the local test validator and the e2e run use (Hyperlane's "solanatestnet"). Devnet is 1399811151.
	SolanaMainnet = uint32(1399811149)
	SolanaLocal   = uint32(1399811150)

	// The launch values (§5.3): the active verifier, the signers and their rule, the routes. The signer keys below
	// are PLACEHOLDERS (the three test signers of the vectors) until the operator's three machines exist; the
	// launch vote reads the real ones in the deployed source. bridge/local/e2e.sh swaps them for its run's keys.
	launchVerifier  = namespace + "hlverifier"
	launchThreshold = 2
	launchSigners   = "e2c2b621677535e5b2a0a92f37aec61e7ce0397cf1cf713f91a18227eafec2ef,d837b6369a315b6d26babddc0af241d8908a1809481b29e98365965cf8301689,c0b2dc0da05eb6ee67b68068611a72858f3093c79e8d90589ff2ac1f0ea4da26"
	launchRouteGNOT   = namespace + "hlgnot"
	launchRouteBUBBLE = namespace + "hlbubble"
	hlgovPath         = namespace + "hlgov" // r/hlgov: the one realm that notes a route's enrolment on Solana (NoteEnrolled, AR1)

	maxSigners = 255 // a signature names its signer in one byte
)

// launchGovernor is the governor (M1k, §5.3): the one address whose own direct call decides — through Govern, the
// same closures, checks, queues and delays a GovDAO proposal's execution runs — until it yields (Yield), from
// which block GovDAO's proposals decide and nothing else; "" means GovDAO from the first block. Every bridge
// realm compiles the same address and refuses to deploy with another (its init reads Governor here), and reads
// Yielded here, so no realm is ever governed apart from the rest. A PLACEHOLDER (testutils.TestAddress("hl-
// governor")) until the launch notice names the real key; bridge/local/e2e.sh swaps it for gnodev's test1 in all
// six realms. Its own line, so one sed on `^const launchGovernor = address(…)` finds it in every realm.
const launchGovernor = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")

var (
	localDomain  = domainOf(runtime.ChainID())
	launchOrigin = solanaOf(runtime.ChainID())
	// hook is this realm's address as Hyperlane carries it: the merkle tree hook id inside every checkpoint signed
	// for a message from here.
	hook = mustBytes32(chain.PackageAddress(pkgPath))

	tree hl.Tree
	sent avl.Tree // nonceKey(nonce) → *sentMsg
	done avl.Tree // message id in hex → the block height it was delivered at

	verifiers avl.Tree // pkgpath → Verifier, every realm that registered
	active    avl.Tree // domainKey(origin) → the pkgpath of the verifier GovDAO chose for that origin

	signerKeys []Key // the one signer set, in the order signatures name them
	signerRule Rule

	live       bool  // after the Launch decision executed
	launchedAt int64 // unix time it did

	yielded int64 // the block height the governor yielded at (Yield); 0 until then — every bridge realm reads it

	ledger decisions.Ledger
)

// sentMsg is one dispatched message and the checkpoint it made.
type sentMsg struct {
	raw    string   // the message as it went out
	root   [32]byte // the tree's root right after its id went in, at index = its nonce
	height int64
}

// Key is a signer's ed25519 public key.
type Key [32]byte

// Rule is how many signers must sign: Threshold of the set, or — when both groups are named (§11.13) — one key of
// GroupA and one of GroupB. The verifier applies it; Satisfiable says whether a set can still meet it.
type Rule struct {
	Threshold int
	GroupA    []Key
	GroupB    []Key
}

// TwoGroups is whether the rule is "one of A and one of B" rather than a threshold.
func (r Rule) TwoGroups() bool { return len(r.GroupA) > 0 && len(r.GroupB) > 0 }

// String says the rule in words.
func (r Rule) String() string {
	if r.TwoGroups() {
		return "one of group A (" + keysHex(r.GroupA) + ") and one of group B (" + keysHex(r.GroupB) + ")"
	}
	return strconv.Itoa(r.Threshold) + " of the set"
}

func (r Rule) equal(o Rule) bool {
	return r.Threshold == o.Threshold && sameKeys(r.GroupA, o.GroupA) && sameKeys(r.GroupB, o.GroupB)
}

// sameAs is whether two rules are the same rule, the groups compared as sets.
func (r Rule) sameAs(o Rule) bool {
	return r.Threshold == o.Threshold && sameSet(r.GroupA, o.GroupA) && sameSet(r.GroupB, o.GroupB)
}

// Verifier decides whether an incoming message is genuine (§5.1). A verifier is a realm; it registers once with
// RegisterVerifier and GovDAO activates it by pkgpath. Both methods are non-crossing. An implementation is a type
// declared in the registering realm: its methods then run under that realm's authority (borrow rule #1) and can
// write nothing of this realm's. A type declared in /p/ with no object to anchor on (`type V int`) would run under
// this realm's own authority instead — the no-anchor case — which RegisterVerifier cannot tell apart, so GovDAO
// activates a verifier whose source it has read; what the mailbox hands a verifier is the recipient's bytes
// (Verify) or a copy of its own keys (Satisfiable), never a value it keeps.
type Verifier interface {
	Verify(origin uint32, metadata, message []byte) error
	Satisfiable(signers []Key) bool
}

func domainOf(chainID string) uint32 {
	if chainID == mainnetChainID {
		return DomainMainnet
	}
	return DomainTest
}

func solanaOf(chainID string) uint32 {
	if chainID == mainnetChainID {
		return SolanaMainnet
	}
	return SolanaLocal
}

func mustBytes32(a address) [32]byte {
	b, err := hl.AddressToBytes32(a)
	if err != nil {
		panic(err.Error())
	}
	return b
}

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	return cur.Previous().Address()
}

func u32(n uint32) string { return strconv.FormatUint(uint64(n), 10) }

func hx(b []byte) string { return hex.EncodeToString(b) }

func keysHex(ks []Key) string {
	s := make([]string, len(ks))
	for i, k := range ks {
		s[i] = hx(k[:])
	}
	return strings.Join(s, ",")
}

// nonceKey sorts nonces by number.
func nonceKey(n uint32) string {
	s := u32(n)
	return strings.Repeat("0", 10-len(s)) + s
}

func domainKey(d uint32) string { return nonceKey(d) }

func init() {
	signerKeys = parseKeys(launchSigners)
	signerRule = Rule{Threshold: launchThreshold}
	active.Set(domainKey(launchOrigin), launchVerifier)
	initSeats()
	routes.Set(launchRouteGNOT, &routeRec{})
	routes.Set(launchRouteBUBBLE, &routeRec{})
}

// ------------------------------------------------------------- reading --

// LocalDomain is this chain's Hyperlane domain id.
func LocalDomain() uint32 { return localDomain }

// LaunchOrigin is the Solana domain the launch values name.
func LaunchOrigin() uint32 { return launchOrigin }

// Address is this realm's address.
func Address() address { return chain.PackageAddress(pkgPath) }

// Hook is this mailbox's merkle tree hook id in hex: the 32 bytes every checkpoint for a message from here names.
func Hook() string { return hx(hook[:]) }

// Count is how many messages went out: the next message's nonce.
func Count() uint32 { return tree.Count }

// Root is the merkle tree's root now, in hex.
func Root() string {
	r := tree.Root()
	return hx(r[:])
}

// Live is whether the Launch decision has executed: before it the routes refuse sends and credits.
func Live() bool { return live }

// LaunchedAt is the unix time the Launch decision executed, 0 before: the routes' meters start empty there.
func LaunchedAt() int64 { return launchedAt }

// Governor is the compiled governor (M1k): the address whose own call decides until it yields; "" when GovDAO
// governs from the first block. Every other bridge realm compiles the same and checks it here at deploy.
func Governor() address { return launchGovernor }

// Yielded is the block height the governor yielded at (Yield), 0 until then: what every bridge realm reads before
// it accepts a decision — the governor's own call before, GovDAO's proxy after (decisions.DAOGoverns).
func Yielded() int64 { return yielded }

// Message is the message dispatched with this nonce, in hex, and the tree's root right after it ("", "" if none).
func Message(nonce uint32) (message, root string) {
	v := sent.Get(nonceKey(nonce))
	if v == nil {
		return "", ""
	}
	s := v.(*sentMsg)
	return hx([]byte(s.raw)), hx(s.root[:])
}

// Delivered is the block height a message (by id, in hex) was delivered at here; 0 if it never was.
func Delivered(id string) int64 {
	v := done.Get(cleanID(id))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func cleanID(id string) string { return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(id)), "0x") }

// Signers is the signer set and its rule: copies, so a verifier can read them and nobody can change them.
func Signers() ([]Key, Rule) {
	ks := append([]Key(nil), signerKeys...)
	r := Rule{Threshold: signerRule.Threshold, GroupA: append([]Key(nil), signerRule.GroupA...), GroupB: append([]Key(nil), signerRule.GroupB...)}
	return ks, r
}

// SignerKeys is the signer set in hex, comma separated, in the order signatures name them.
func SignerKeys() string { return keysHex(signerKeys) }

// ActiveVerifier is the pkgpath of the verifier GovDAO chose for an origin ("" if none).
func ActiveVerifier(origin uint32) string {
	v := active.Get(domainKey(origin))
	if v == nil {
		return ""
	}
	return v.(string)
}

// VerifierRegistered is whether a realm at this pkgpath registered as a verifier.
func VerifierRegistered(path string) bool { return verifiers.Has(path) }

// --------------------------------------------------------------- keys --

func parseKey(s string) Key {
	p := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(s)), "0x")
	b, err := hex.DecodeString(p)
	if err != nil || len(b) != 32 {
		panic("hlmailbox: not a 32-byte ed25519 key in hex: " + p)
	}
	var k Key
	copy(k[:], b)
	return k
}

// parseKeys reads comma-separated keys in hex, refusing a key named twice.
func parseKeys(s string) []Key {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	if len(parts) > maxSigners {
		panic("hlmailbox: more than 255 keys")
	}
	ks := make([]Key, 0, len(parts))
	for _, p := range parts {
		k := parseKey(p)
		if indexOf(ks, k) >= 0 {
			panic("hlmailbox: a key named twice: " + hx(k[:]))
		}
		ks = append(ks, k)
	}
	return ks
}

func indexOf(ks []Key, k Key) int {
	for i, x := range ks {
		if x == k {
			return i
		}
	}
	return -1
}

// sameKeys is whether two lists hold the same keys in the same order.
func sameKeys(a, b []Key) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// subset is whether every key of a is in b.
func subset(a, b []Key) bool {
	for _, k := range a {
		if indexOf(b, k) < 0 {
			return false
		}
	}
	return true
}

// sameSet is whether two lists hold the same keys, in any order (a list never names a key twice).
func sameSet(a, b []Key) bool { return len(a) == len(b) && subset(a, b) && subset(b, a) }

// ----------------------------------------------------------- verifiers --

// RegisterVerifier is how a verifier realm offers itself: called once from that realm (its init, usually), it is
// kept under the caller's pkgpath, which GovDAO names to activate it. Only an /r/ realm may register, and once;
// a sub-realm identity (`cur.Sub(…)`, a token a realm mints for free, whose pkgpath `host#subpath` passes the
// prefix test) is refused, so every entry costs a package deployment and the listing (bounded; render.gno)
// cannot be flooded. Nothing is ever unregistered.
func RegisterVerifier(cur realm, v Verifier) {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	path := cur.Previous().PkgPath()
	if !strings.HasPrefix(path, "gno.land/r/") {
		panic("hlmailbox: only a realm under gno.land/r/ registers a verifier, not " + path)
	}
	if cur.Previous().Subpath() != "" {
		panic("hlmailbox: a realm registers with its own cur, not a sub-identity (" + path + ")")
	}
	if v == nil {
		panic("hlmailbox: a nil verifier")
	}
	if verifiers.Has(path) {
		panic("hlmailbox: " + path + " registered already")
	}
	verifiers.Set(path, v)
	chain.Emit("VerifierRegistered", "pkgpath", path)
}

// satisfiable asks every active verifier whether the signer set ks can still meet the rule; an active verifier
// that is not registered answers no. Each verifier is handed its own copy of ks: the builders store ks after
// asking, and a verifier that runs under this realm's authority (the no-anchor case, see Verifier) must find
// nothing of the mailbox's to write into.
func satisfiable(ks []Key) bool {
	ok := true
	active.Iterate("", "", func(_ string, v any) bool {
		path := v.(string)
		r := verifiers.Get(path)
		if r == nil || !r.(Verifier).Satisfiable(append([]Key(nil), ks...)) {
			ok = false
			return true
		}
		return false
	})
	return ok
}

// ---------------------------------------------------------------- out --

// Dispatch sends body to recipient on destination, from whoever calls it — a realm, usually — and returns the
// message's id. The sender is the caller's address as Hyperlane carries one; the nonce is the message's index in
// the merkle tree. The event is §13's: id, nonce, origin, destination, sender, recipient, hash.
func Dispatch(cur realm, destination uint32, recipient [32]byte, body []byte) [32]byte {
	sender := mustBytes32(caller(cur))
	// a successor a re-point dropped is a route no more (R35): Solana's token may still name it the router until
	// the next kind 6, so a message from it would mint against a lock no realm of the line holds
	if path := cur.Previous().PkgPath(); path != "" {
		if by := Dropped(path); by != "" {
			panic("hlmailbox: " + path + " is a route no more (its predecessor " + by + " re-pointed the migration to another successor): it sends nothing")
		}
	}
	m := hl.Message{
		Version:     hl.Version,
		Nonce:       tree.Count,
		Origin:      localDomain,
		Sender:      sender,
		Destination: destination,
		Recipient:   recipient,
		Body:        body,
	}
	raw := m.Bytes()
	id := hl.ID(raw)
	tree.Insert(id)
	root := tree.Root()
	sent.Set(nonceKey(m.Nonce), &sentMsg{raw: string(raw), root: root, height: runtime.ChainHeight()})
	emitDispatch(m, raw, id)
	return id
}

func emitDispatch(m hl.Message, raw []byte, id [32]byte) {
	h := sha256.Sum256(raw)
	chain.Emit("Dispatch",
		"id", hx(id[:]),
		"nonce", u32(m.Nonce),
		"origin", u32(m.Origin),
		"destination", u32(m.Destination),
		"sender", hx(m.Sender[:]),
		"recipient", hx(m.Recipient[:]),
		"hash", hx(h[:]),
	)
}

// Reemit emits the Dispatch event of a message dispatched earlier again, in this block, by anyone: a message
// dispatched before a validator-set change, or whose results leaf is bigger than the ISM accepts, is then delivered
// from a fresh header. The id is unchanged, so the other side's processed-message record still refuses a second
// delivery.
func Reemit(cur realm, nonce uint32) {
	caller(cur)
	v := sent.Get(nonceKey(nonce))
	if v == nil {
		panic("hlmailbox: no message with nonce " + u32(nonce))
	}
	raw := []byte(v.(*sentMsg).raw)
	m, err := hl.ParseMessage(raw)
	if err != nil {
		panic(err.Error())
	}
	emitDispatch(m, raw, hl.ID(raw))
}

// ----------------------------------------------------------------- in --

// Process takes a message from another chain for the caller, who must be its recipient — or a route that
// succeeds the recipient along the chain of migrations (AQ1: a burn addressed to a migrated route is the
// successor's to credit, once its last page is in; the route decides when), a successor a re-point dropped from
// that chain counted as a hop of its predecessor's (R35: the line's last realm takes what is addressed to it; the
// dropped realm itself, a route no more, is refused). metadata is whatever the origin's active verifier needs
// (the signers' checkpoint and signatures, for the ed25519 one). The message must be for this chain and never
// delivered; it is marked delivered, then the verifier is asked, and a verifier's error is a panic, so the whole
// transaction reverts with the mark and the message stays deliverable (§5.1). It is then handed back for the
// recipient to act on.
func Process(cur realm, metadata, message []byte) (origin uint32, sender [32]byte, body []byte) {
	who := caller(cur)
	callerPath := cur.Previous().PkgPath()
	if by := Dropped(callerPath); by != "" {
		panic("hlmailbox: " + callerPath + " is a route no more (its predecessor " + by + " re-pointed the migration to another successor): the line's last realm takes this message")
	}
	m, err := hl.ParseMessage(message)
	if err != nil {
		panic(err.Error())
	}
	if m.Version != hl.Version {
		panic("hlmailbox: message version " + strconv.Itoa(int(m.Version)) + ", not " + strconv.Itoa(hl.Version))
	}
	if m.Destination != localDomain {
		panic("hlmailbox: the message is for domain " + u32(m.Destination) + ", not this one (" + u32(localDomain) + ")")
	}
	if mustBytes32(who) != m.Recipient && !successorOf(callerPath, m.Recipient) {
		panic("hlmailbox: only the message's recipient, or a successor of it, can take it")
	}
	idb := hl.ID(message)
	id := hx(idb[:])
	if done.Has(id) {
		panic("hlmailbox: already delivered")
	}
	path := active.Get(domainKey(m.Origin))
	if path == nil {
		panic("hlmailbox: no verifier for domain " + u32(m.Origin))
	}
	v := verifiers.Get(path.(string))
	if v == nil {
		panic("hlmailbox: the active verifier " + path.(string) + " is not registered")
	}
	done.Set(id, runtime.ChainHeight())
	if err := v.(Verifier).Verify(m.Origin, metadata, message); err != nil {
		panic(err.Error())
	}
	chain.Emit("Process",
		"origin", u32(m.Origin),
		"nonce", u32(m.Nonce),
		"id", id,
		"sender", hx(m.Sender[:]),
		"recipient", hx(m.Recipient[:]),
	)
	return m.Origin, m.Sender, m.Body
}

// MarkDone marks a message id delivered without a message: a route's credit-by-vote (§5.3) does it, so the id
// can never be credited twice. Only a registered route may call it, and only for an id not done.
func MarkDone(cur realm, id string) {
	mustBeRoute(cur)
	id = cleanID(id)
	if b, err := hex.DecodeString(id); err != nil || len(b) != 32 {
		panic("hlmailbox: not a 32-byte message id in hex: " + id)
	}
	if done.Has(id) {
		panic("hlmailbox: already delivered")
	}
	done.Set(id, runtime.ChainHeight())
}
