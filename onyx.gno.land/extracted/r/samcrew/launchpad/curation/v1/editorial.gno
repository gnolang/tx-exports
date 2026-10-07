package curation

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

const (
	maxFeature = 14 * 24 * 60 * 60 // seconds
	holdSpan   = 24 * 60 * 60
	maxHold    = 30 * 24 * 60 * 60
)

// What a founder may appeal: the decision on its application, a hold, the
// collection's verification, or a feature decision.
var subjects = [...]string{"application", "hold", "verification", "feature"}

// A feature slot exists only when one manager proposed it and another
// approved it. The admin can clear a slot and can never create one.
type feature struct {
	collection string
	proposer   address
	approver   address // empty until approved
	reasonHash string
	reasonCID  string
	until      int64
}

// A hold hides a collection from curated views until a time. It changes
// presentation only: nothing about the collection's tokens is frozen.
type hold struct {
	actor      address
	confirmer  address // empty until a second manager confirms
	extended   bool    // the admin set the term and its reason
	reasonHash string
	reasonCID  string
	until      int64
}

type verification struct {
	verified   bool
	reasonHash string
	reasonCID  string
	updatedAt  int64
}

type appeal struct {
	collection    string
	subject       string
	statementHash string
	statementCID  string
	filedAt       int64
	openKey       string // its key in openAppeals; empty once resolved
	upheld        bool
	reasonHash    string
	reasonCID     string
	resolvedAt    int64
}

var (
	features      avl.Tree // collection -> *feature
	holds         avl.Tree // collection -> *hold
	verifications avl.Tree // collection -> verification
	appeals       avl.Tree // "<collection>/<subject>" -> *appeal, the latest
	lastAppeal    seqid.ID
	openAppeals   avl.Tree // seqid key -> appeals key, in filing order
)

func featureOf(collection string) *feature {
	if f := features.Get(collection); f != nil {
		return f.(*feature)
	}
	return nil
}

func holdOf(collection string) *hold {
	if h := holds.Get(collection); h != nil {
		return h.(*hold)
	}
	return nil
}

func appealOf(key string) *appeal {
	if a := appeals.Get(key); a != nil {
		return a.(*appeal)
	}
	return nil
}

// standing reports whether who could act on the collection as a manager now.
// An unapproved slot's empty approver holds no seat.
func standing(collection string, who address) bool {
	return active(who) && !conflicted(nft.GetInfo(collection), who)
}

// pair enforces the two-manager rule when second completes what first began:
// two different managers, the first still seated and unconflicted. The second
// was checked as the caller.
func pair(collection string, first, second address) {
	if first == second || !standing(collection, first) {
		panic("launchpad/curation: a second unconflicted manager is required")
	}
}

// running reports a slot that runs, approved by two managers that both keep
// their standing: whether hidden or not, it is the collection's slot.
func running(collection string, f *feature) bool {
	return now() < f.until &&
		standing(collection, f.proposer) && standing(collection, f.approver)
}

// ProposeFeature opens a slot of at most 14 days. It features nothing until
// a second manager approves. It replaces a slot that is not running: one
// still unapproved, or one whose proposer or approver lost its standing.
func ProposeFeature(cur realm, collection, reasonHash, reasonCID string, until int64) {
	who := manager(cur, collection)
	commitment(reasonHash, reasonCID)
	at := now()
	if until <= at || until > at+maxFeature {
		panic("launchpad/curation: invalid feature term")
	}
	if f := featureOf(collection); f != nil && running(collection, f) {
		panic("launchpad/curation: feature slot running")
	}
	features.Set(collection, &feature{collection: collection, proposer: who,
		reasonHash: reasonHash, reasonCID: reasonCID, until: until})
	chain.Emit("FeatureProposed", "collection", collection,
		"manager", who.String(), "until", strconv.FormatInt(until, 10),
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

func ApproveFeature(cur realm, collection string) {
	who := manager(cur, collection)
	f := featureOf(collection)
	if f == nil || f.approver != "" || now() >= f.until {
		panic("launchpad/curation: no feature slot awaiting approval")
	}
	pair(collection, f.proposer, who)
	f.approver = who
	chain.Emit("FeatureApproved", "collection", collection,
		"proposer", f.proposer.String(), "manager", who.String(),
		"until", strconv.FormatInt(f.until, 10))
}

// IsFeatured holds only while the slot runs, both of its managers keep their
// standing and the collection is not hidden.
func IsFeatured(collection string) bool {
	f := featureOf(collection)
	return f != nil && running(collection, f) && !IsHidden(collection)
}

func ClearFeature(cur realm, collection, reasonHash, reasonCID string) {
	requireAdmin(cur)
	commitment(reasonHash, reasonCID)
	if _, had := features.Remove(collection); !had {
		panic("launchpad/curation: no feature slot")
	}
	chain.Emit("FeatureCleared", "collection", collection,
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

// HideTemporarily hides a collection for 24 hours on one manager's word. The
// record outlives the hold: no manager can start another until the admin
// clears it.
func HideTemporarily(cur realm, collection, reasonHash, reasonCID string) {
	who := manager(cur, collection)
	commitment(reasonHash, reasonCID)
	if holds.Has(collection) {
		panic("launchpad/curation: a hold is on record until the admin clears it")
	}
	until := now() + holdSpan
	holds.Set(collection, &hold{actor: who, reasonHash: reasonHash,
		reasonCID: reasonCID, until: until})
	chain.Emit("HideStarted", "collection", collection,
		"manager", who.String(), "until", strconv.FormatInt(until, 10),
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

// ConfirmHide lets a second manager keep a running hold for 24 hours from
// now, once. After that, or once the admin has set the term, only the admin
// changes it.
func ConfirmHide(cur realm, collection string) {
	who := manager(cur, collection)
	h := holdOf(collection)
	at := now()
	if h == nil || h.confirmer != "" || h.extended || at >= h.until {
		panic("launchpad/curation: no hold awaiting confirmation")
	}
	pair(collection, h.actor, who)
	h.confirmer, h.until = who, at+holdSpan
	chain.Emit("HideConfirmed", "collection", collection,
		"manager", who.String(), "until", strconv.FormatInt(h.until, 10))
}

// ExtendHide sets the term of a recorded hold, running or over, to a time at
// most 30 days ahead, and replaces its public reason.
func ExtendHide(cur realm, collection string, until int64, reasonHash, reasonCID string) {
	requireAdmin(cur)
	commitment(reasonHash, reasonCID)
	h := holdOf(collection)
	at := now()
	if h == nil || until <= at || until > at+maxHold {
		panic("launchpad/curation: invalid hold extension")
	}
	h.extended, h.until, h.reasonHash, h.reasonCID = true, until, reasonHash, reasonCID
	chain.Emit("HideExtended", "collection", collection,
		"until", strconv.FormatInt(until, 10),
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

func ClearHide(cur realm, collection, reasonHash, reasonCID string) {
	requireAdmin(cur)
	commitment(reasonHash, reasonCID)
	if _, had := holds.Remove(collection); !had {
		panic("launchpad/curation: no hold on record")
	}
	chain.Emit("HideCleared", "collection", collection,
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

// IsHidden holds while the hold runs and the manager whose word set its term
// keeps its standing: the starter, or the confirmer once it confirmed. A term
// the admin set rests on the admin alone.
func IsHidden(collection string) bool {
	h := holdOf(collection)
	switch {
	case h == nil || now() >= h.until:
		return false
	case h.extended:
		return true
	case h.confirmer != "":
		return standing(collection, h.confirmer)
	}
	return standing(collection, h.actor)
}

// SetVerified is the admin's statement that a collection is what it claims
// to be. It says nothing about price or future value.
func SetVerified(cur realm, collection string, value bool, reasonHash, reasonCID string) {
	requireAdmin(cur)
	nft.GetInfo(collection)
	commitment(reasonHash, reasonCID)
	if IsVerified(collection) == value {
		panic("launchpad/curation: verification unchanged")
	}
	verifications.Set(collection, verification{value, reasonHash, reasonCID, now()})
	chain.Emit("VerificationChanged", "collection", collection,
		"verified", strconv.FormatBool(value),
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}

func IsVerified(collection string) bool {
	v := verifications.Get(collection)
	return v != nil && v.(verification).verified
}

// Appeal files the founder's objection on one subject. A collection has at
// most one open appeal per subject; a resolved one can be followed by another.
func Appeal(cur realm, collection, subject, statementHash, statementCID string) {
	who := founder(cur, collection)
	known := false
	for _, s := range subjects {
		known = known || s == subject
	}
	if !known {
		panic("launchpad/curation: invalid appeal subject")
	}
	commitment(statementHash, statementCID)
	key := collection + "/" + subject
	if a := appealOf(key); a != nil && a.openKey != "" {
		panic("launchpad/curation: appeal already open")
	}
	openKey := lastAppeal.Next().String()
	appeals.Set(key, &appeal{collection: collection, subject: subject,
		statementHash: statementHash, statementCID: statementCID,
		filedAt: now(), openKey: openKey})
	openAppeals.Set(openKey, key)
	chain.Emit("AppealFiled", "collection", collection, "subject", subject,
		"founder", who.String(),
		"statement_hash", statementHash, "statement_cid", statementCID)
}

// ResolveAppeal records the admin's answer and its public reason. It changes
// nothing else: the admin acts on an upheld appeal with the ordinary calls.
func ResolveAppeal(cur realm, collection, subject string, upheld bool, reasonHash, reasonCID string) {
	requireAdmin(cur)
	commitment(reasonHash, reasonCID)
	a := appealOf(collection + "/" + subject)
	if a == nil || a.openKey == "" {
		panic("launchpad/curation: no open appeal")
	}
	openAppeals.Remove(a.openKey)
	a.openKey, a.upheld, a.resolvedAt = "", upheld, now()
	a.reasonHash, a.reasonCID = reasonHash, reasonCID
	chain.Emit("AppealResolved", "collection", collection, "subject", subject,
		"upheld", strconv.FormatBool(upheld),
		"reason_hash", reasonHash, "reason_cid", reasonCID)
}
