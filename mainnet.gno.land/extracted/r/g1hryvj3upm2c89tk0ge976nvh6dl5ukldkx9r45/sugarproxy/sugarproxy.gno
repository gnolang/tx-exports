// Package sugarproxy holds the rules of sugar proxy (sugar repo, PROXY.md): which sites sharers' home connections
// may carry, for which customers and why; which app releases they may run; which hubs they may connect to; who pays
// them. Sharers' apps read these rules through a light client, from one parameter this realm writes on every change
// (params "doc": the canonical JSON of everything below), so no hub can change what a sharer's connection does.
//
// Who decides:
//   - Holders of the SUGAR token, through kourt's governor (govern.gno): they add and remove anything.
//   - A delegate realm, if they name one (gno.security's, say): it adds and removes sites, nothing else.
//   - GovDAO (govdao.gno), above both: it adds and removes anything at once, vetoes, pauses, and names the delegate
//     and the guardian. A guardian it names (the deployer, at first) may veto and pause, never approve.
//
// Anything added by the token or the delegate waits out a veto window before it counts; GovDAO's own additions
// count at once. A veto or a removal counts at once, whoever makes it.
package sugarproxy

import (
	"chain"
	"chain/params"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

func errorf(format string, args ...any) error { return ufmt.Errorf(format, args...) }

// Item is one entry of the rules: a site, a release, a hub, a customer or a payer.
type Item struct {
	ID       int
	Kind     string // KindSite, KindRelease, KindHub, KindCustomer, KindPayer
	Fields   []string
	State    string // StateApproved, StateVetoed, StateRevoked
	By       string // who added it: "init", "token", "delegate", "govdao"
	Approved int64  // unix seconds
	After    int64  // unix seconds: when its veto window ends and it counts
	Note     string // who vetoed or removed it, and when
}

const (
	KindSite     = "site"     // fields: pattern, customer, purpose
	KindRelease  = "release"  // fields: version, platform, sha256, url
	KindHub      = "hub"      // fields: host:port, pin (hex sha256 of its certificate's public key)
	KindCustomer = "customer" // fields: name, purpose
	KindPayer    = "payer"    // fields: address (may call Pay)

	StateApproved = "approved"
	StateVetoed   = "vetoed"
	StateRevoked  = "revoked"
)

var (
	items     []*Item
	nextID    = 1
	paused    bool
	delegate  string  // the realm path that may add and remove sites; "" is none
	guardian  address // may veto and pause; GovDAO names it
	vetoWin   = map[string]int64{KindSite: 3 * 86400, KindRelease: 7 * 86400, KindHub: 3 * 86400, KindCustomer: 3 * 86400, KindPayer: 3 * 86400}
	doc       string // the canonical JSON the apps read, as params "doc"
	digest    string // its hex sha256
	docSeq    int    // how many times it has changed
	requests  []*Request
	nextReqID = 1
	launching bool // launch.gno: while the first install's items go in
)

// Request is anyone's suggestion of an item, for the token holders or the delegate to consider. It changes nothing.
type Request struct {
	ID      int
	By      address
	Payload string
	Reason  string
	Time    int64
	Done    bool
}

func init(cur realm) {
	setupGovernor()
	// The owner (launch.gno; the deployer when unset) is the first guardian (GovDAO can replace it) and holds the
	// whole first supply of SUGAR (govern.gno).
	who := owner
	if who == "" {
		who = cur.Previous().Address()
	}
	if who != "" {
		guardian = who
		mintInitial(who)
	}
	launch()
	publish()
}

// --- what an item may say ---

// parse turns "kind|field|field..." into an item's kind and fields, checking each field.
func parse(payload string) (string, []string, error) {
	parts := strings.Split(payload, "|")
	kind, f := parts[0], parts[1:]
	want := map[string]int{KindSite: 3, KindRelease: 4, KindHub: 2, KindCustomer: 2, KindPayer: 1}[kind]
	if want == 0 {
		return "", nil, errorf("unknown kind %q: site, release, hub, customer or payer", kind)
	}
	if len(f) != want {
		return "", nil, errorf("a %s has %d fields, separated by |", kind, want)
	}
	for _, x := range f {
		if len(x) == 0 || len(x) > 300 || strings.ContainsAny(x, "\n\r\t") {
			return "", nil, errorf("each field is 1 to 300 characters on one line")
		}
	}
	switch kind {
	case KindSite:
		if !sitePattern(f[0]) {
			return "", nil, errorf("%q is not a site: a lowercase DNS name, or *. and one", f[0])
		}
		if !customerActive(f[1]) {
			return "", nil, errorf("no customer %q is approved", f[1])
		}
	case KindRelease:
		if !word(f[0], 1, 32) || !word(f[1], 3, 32) || !hexOf(f[2], 64) || !strings.HasPrefix(f[3], "https://") {
			return "", nil, errorf("a release is version|platform|sha256 (64 hex)|https://url")
		}
	case KindHub:
		host, port, ok := strings.Cut(f[0], ":")
		n, err := strconv.Atoi(port)
		if !ok || !sitePattern(host) || strings.HasPrefix(host, "*.") || err != nil || n < 1 || n > 65535 || !hexOf(f[1], 64) {
			return "", nil, errorf("a hub is host:port|pin (64 hex)")
		}
	case KindCustomer:
		if !word(f[0], 2, 32) {
			return "", nil, errorf("a customer's name is 2 to 32 of a-z, 0-9 and -")
		}
	case KindPayer:
		if !address(f[0]).IsValid() {
			return "", nil, errorf("%q is not an address", f[0])
		}
	}
	return kind, f, nil
}

func word(s string, min, max int) bool {
	if len(s) < min || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_') {
			return false
		}
	}
	return true
}

func hexOf(s string, n int) bool {
	if len(s) != n {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && strings.ToLower(s) == s
}

// sitePattern is a lowercase DNS name of two or more labels, or "*." and one: what an app matches a host against.
func sitePattern(s string) bool {
	s = strings.TrimPrefix(s, "*.")
	if len(s) > 253 {
		return false
	}
	labels := strings.Split(s, ".")
	if len(labels) < 2 {
		return false
	}
	for _, l := range labels {
		if len(l) == 0 || len(l) > 63 || l[0] == '-' || l[len(l)-1] == '-' {
			return false
		}
		for i := 0; i < len(l); i++ {
			c := l[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return strings.Trim(labels[len(labels)-1], "0123456789") != ""
}

func customerActive(name string) bool {
	now := time.Now().Unix()
	for _, it := range items {
		if it.Kind == KindCustomer && it.Fields[0] == name && it.State == StateApproved && now >= it.After {
			return true
		}
	}
	return false
}

// --- changes: every one goes through here and republishes the doc ---

// add puts an item in, approved. by says who: its veto window applies unless GovDAO added it.
func add(payload, by string) (int, error) {
	if paused && by != "govdao" {
		return 0, errorf("sugar proxy is paused")
	}
	kind, fields, err := parse(payload)
	if err != nil {
		return 0, err
	}
	if by == "delegate" && kind != KindSite {
		return 0, errorf("the delegate adds sites only")
	}
	for _, it := range items {
		if it.Kind == kind && strings.Join(it.Fields, "|") == strings.Join(fields, "|") && it.State == StateApproved {
			return 0, errorf("item %d already says that", it.ID)
		}
	}
	now := time.Now().Unix()
	after := now + vetoWin[kind]
	if by == "govdao" || by == "init" || by == "launcher" {
		after = now // GovDAO is the veto; the first install is signed by Jae; the launcher's sites are removable at once
	}
	it := &Item{ID: nextID, Kind: kind, Fields: fields, State: StateApproved, By: by, Approved: now, After: after}
	nextID++
	items = append(items, it)
	for _, r := range requests {
		if !r.Done && r.Payload == payload {
			r.Done = true
		}
	}
	chain.Emit("Added", "id", strconv.Itoa(it.ID), "kind", kind, "by", by, "after", strconv.FormatInt(after, 10))
	publish()
	return it.ID, nil
}

// end vetoes or removes an item: a veto only while its window is open, a removal any time. It counts at once.
func end(id int, veto bool, by string) error {
	it := find(id)
	if it == nil {
		return errorf("no item %d", id)
	}
	if it.State != StateApproved {
		return errorf("item %d is already %s", id, it.State)
	}
	now := time.Now().Unix()
	if veto {
		if now >= it.After {
			return errorf("item %d's veto window is over; remove it instead", id)
		}
		it.State = StateVetoed
	} else {
		it.State = StateRevoked
	}
	it.Note = it.State + " by " + by + " at " + strconv.FormatInt(now, 10)
	chain.Emit("Ended", "id", strconv.Itoa(id), "state", it.State, "by", by)
	publish()
	return nil
}

func setPaused(on bool, by string) {
	if paused == on {
		return
	}
	paused = on
	chain.Emit("Paused", "on", strconv.FormatBool(on), "by", by)
	publish()
}

func find(id int) *Item {
	for _, it := range items {
		if it.ID == id {
			return it
		}
	}
	return nil
}

// publish writes the doc the apps read: params "doc", at gno.land's main store key
// "/pv/vm:<this realm's path>:doc", which a light client proves against a block's app hash.
func publish() {
	if launching {
		return
	}
	doc = render()
	sum := sha256.Sum256([]byte(doc))
	digest = hex.EncodeToString(sum[:])
	docSeq++
	params.SetBytes("doc", []byte(doc))
}

// render is the canonical JSON of the rules: every item ever approved, in order, with its state, so an app can
// tell what counts at any time (approved, and its After passed) without trusting anyone's clock but its own.
func render() string {
	var b strings.Builder
	b.WriteString(`{"v":1,"seq":`)
	b.WriteString(strconv.Itoa(docSeq + 1))
	b.WriteString(`,"paused":`)
	b.WriteString(strconv.FormatBool(paused))
	b.WriteString(`,"items":[`)
	for i, it := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"id":`)
		b.WriteString(strconv.Itoa(it.ID))
		b.WriteString(`,"kind":`)
		b.WriteString(jstr(it.Kind))
		b.WriteString(`,"fields":[`)
		for j, f := range it.Fields {
			if j > 0 {
				b.WriteByte(',')
			}
			b.WriteString(jstr(f))
		}
		b.WriteString(`],"state":`)
		b.WriteString(jstr(it.State))
		b.WriteString(`,"by":`)
		b.WriteString(jstr(it.By))
		b.WriteString(`,"approved":`)
		b.WriteString(strconv.FormatInt(it.Approved, 10))
		b.WriteString(`,"after":`)
		b.WriteString(strconv.FormatInt(it.After, 10))
		b.WriteByte('}')
	}
	b.WriteString(`]}`)
	return b.String()
}

// jstr quotes s as a JSON string.
func jstr(s string) string {
	const hexd = "0123456789abcdef"
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hexd[c>>4])
			b.WriteByte(hexd[c&15])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// --- reading ---

// Doc is the canonical JSON the apps read (the same bytes as params "doc"); Digest is its hex sha256.
func Doc() string    { return doc }
func Digest() string { return digest }

// ItemID is the number of the approved item that says exactly payload ("kind|field|..."), or 0.
func ItemID(payload string) int {
	for _, it := range items {
		if it.State == StateApproved && it.Kind+"|"+joinFields(it.Fields) == payload {
			return it.ID
		}
	}
	return 0
}

// Paused reports whether sugar proxy is paused: apps carry nothing while it is.
func Paused() bool { return paused }

// Delegate is the realm that may add and remove sites ("" is none); Guardian may veto and pause.
func Delegate() string  { return delegate }
func Guardian() address { return guardian }

// VetoWindow is how long an added item of a kind waits before it counts, in seconds.
func VetoWindow(kind string) int64 { return vetoWin[kind] }

// --- anyone ---

// Suggest records a suggestion of an item ("kind|field|..."), for the token holders or the delegate to consider. It
// changes nothing. Each address may have three open at a time.
func Suggest(cur realm, payload, reason string) int {
	by := mustUser(cur)
	if _, _, err := parse(payload); err != nil {
		panic(err.Error())
	}
	if len(reason) > 500 {
		panic("the reason is at most 500 characters")
	}
	open := 0
	for _, r := range requests {
		if r.By == by && !r.Done {
			open++
		}
	}
	if open >= 3 {
		panic("you have three suggestions open already")
	}
	r := &Request{ID: nextReqID, By: by, Payload: payload, Reason: reason, Time: time.Now().Unix()}
	nextReqID++
	requests = append(requests, r)
	chain.Emit("Suggested", "id", strconv.Itoa(r.ID), "by", by.String())
	return r.ID
}

// Withdraw closes your own suggestion.
func Withdraw(cur realm, id int) {
	by := mustUser(cur)
	for _, r := range requests {
		if r.ID == id && r.By == by {
			r.Done = true
			return
		}
	}
	panic("no suggestion of yours has that id")
}

// --- the delegate realm ---

// DelegateAdd adds a site ("site|pattern|customer|purpose"), from the delegate realm only; it waits out the
// site veto window.
func DelegateAdd(cur realm, payload string) int {
	mustDelegate(cur)
	id, err := add(payload, "delegate")
	if err != nil {
		panic(err.Error())
	}
	return id
}

// DelegateRemove removes a site, from the delegate realm only.
func DelegateRemove(cur realm, id int) {
	mustDelegate(cur)
	if it := find(id); it == nil || it.Kind != KindSite {
		panic("the delegate removes sites only")
	}
	if err := end(id, false, "delegate"); err != nil {
		panic(err.Error())
	}
}

// mustDelegate refuses any caller but the delegate realm itself, the way r/sys/params checks its delegates: none
// named refuses everyone, and the caller's realm path must match exactly.
func mustDelegate(cur realm) {
	if delegate == "" {
		panic("no delegate is named")
	}
	if cur.Previous().PkgPath() != delegate {
		panic("only the delegate realm " + delegate + " may do that")
	}
}

// --- the guardian ---

// GuardianVeto vetoes an item still in its veto window.
func GuardianVeto(cur realm, id int) {
	mustGuardian(cur)
	if err := end(id, true, "guardian"); err != nil {
		panic(err.Error())
	}
}

// GuardianRemove removes a site, at once: the safe direction, so the guardian may (the launcher's sites count at
// once, so there is no window to veto them in).
func GuardianRemove(cur realm, id int) {
	mustGuardian(cur)
	if it := find(id); it == nil || it.Kind != KindSite {
		panic("the guardian removes sites only")
	}
	if err := end(id, false, "guardian"); err != nil {
		panic(err.Error())
	}
}

// GuardianPause pauses or resumes sugar proxy.
func GuardianPause(cur realm, on bool) {
	mustGuardian(cur)
	setPaused(on, "guardian")
}

func mustGuardian(cur realm) {
	if guardian == "" || mustUser(cur) != guardian {
		panic("only the guardian may do that")
	}
}

// mustUser returns the caller, who must be a user, not another realm's code.
func mustUser(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUser() {
		panic("only a user may call this")
	}
	return prev.Address()
}
