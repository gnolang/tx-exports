// Package reputation is Guildhall's record of completed work.
//
// Every record says that a piece of work was paid for, who did it, who vouched
// for it, how much it paid and where the work lives (a PR, a realm path, a
// proposal). Records can only be written by allowlisted writer realms, the
// Guildhall bounty escrow first among them, and only at the moment escrowed
// funds are released. Each record also keeps the address whose signed
// transaction released the funds.
//
// Scores are derived from those records with the rules in
// gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/trust: a record is worth more when the people who
// approved it are themselves trusted. Any realm can consume the result with a
// single import:
//
//	import "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
//
//	func Vote(cur realm, ...) {
//		reputation.AssertScore(cur.Previous().Address(), 300)
//		...
//	}
package reputation

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/trust/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

// BountiesPath is the escrow realm allowed to write records at launch.
const BountiesPath = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties"

const (
	maxReviewers = 16
	maxTextLen   = 300
	maxRank      = 1000
)

// entry is what a writer realm submits when work is paid for.
type entry struct {
	Worker     address
	Poster     address
	Reviewers  []address
	ShareBps   int64
	Amount     int64
	Denom      string
	Title      string
	Link       string
	Ref        string
	Arbitrated bool
}

// Record is a stored, immutable account of paid work. Only Voided can change,
// and only by the Guildhall admin.
type Record struct {
	ID            uint64
	Worker        address
	Poster        address
	Reviewers     []address
	ReviewerTrust []int64
	Points        int64
	ShareBps      int64
	Amount        int64
	Denom         string
	Title         string
	Link          string
	Ref           string
	Source        string
	SignedBy      address
	Arbitrated    bool
	Height        int64
	At            time.Time
	Voided        bool
	VoidReason    string
}

// Profile aggregates a contributor's records.
type Profile struct {
	Addr    address
	Score   int64
	Records []uint64
	Reviews []uint64
	First   time.Time
	Last    time.Time
	earned  *avl.Tree // denom -> int64
}

// Standing is a leaderboard entry.
type Standing struct {
	Addr  address
	Score int64
}

var (
	records     avl.Tree // padded id -> *Record
	lastID      uint64
	profiles    avl.Tree // address -> *Profile
	leaderboard avl.Tree // inverted score key -> address
	seeds       avl.Tree // address -> struct{}
	writers     avl.Tree // pkgpath -> struct{}
	params      = trust.DefaultParams()
	admin       *ownable.Ownable
)

// InitialAdmin owns this namespace and is the only key that can deploy here.
// It starts out as the admin; TransferAdmin can hand the role on.
const InitialAdmin address = "g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm"

func init() {
	admin = ownable.NewWithAddress(InitialAdmin)
	writers.Set(BountiesPath, struct{}{})
}

// ---------------------------------------------------------------------------
// Writing

// AddRecord stores a piece of paid work and credits the worker. It may only be
// called by an allowlisted writer realm, at the moment it releases funds.
//
// worker was paid amount of denom for work funded by poster and approved by
// reviewers. shareBps is the fraction of the milestone the worker received
// (10000 unless a dispute split it). title, link and ref describe the work:
// link points at the PR, realm path or proposal, and ref identifies the
// work within the writer realm (for bounties, "<id>/<milestone>").
func AddRecord(cur realm, worker, poster address, reviewers []address, shareBps, amount int64, denom, title, link, ref string, arbitrated bool) uint64 {
	e := entry{
		Worker:     worker,
		Poster:     poster,
		Reviewers:  reviewers,
		ShareBps:   shareBps,
		Amount:     amount,
		Denom:      denom,
		Title:      title,
		Link:       link,
		Ref:        ref,
		Arbitrated: arbitrated,
	}
	src := cur.Previous().PkgPath()
	if src == "" || !writers.Has(src) {
		panic("reputation: " + strconv.Quote(src) + " is not an allowed writer")
	}
	if err := validateEntry(e); err != nil {
		panic(err.Error())
	}

	vouchers := make([]trust.Reviewer, len(e.Reviewers))
	for i, r := range e.Reviewers {
		vouchers[i] = trust.Reviewer{Addr: r, Score: Score(r), Seed: IsSeed(r)}
	}
	res, err := trust.Evaluate(trust.Input{
		Worker:    e.Worker,
		Poster:    e.Poster,
		Reviewers: vouchers,
		ShareBps:  e.ShareBps,
	}, params)
	if err != nil {
		panic(err.Error())
	}

	lastID++
	rec := &Record{
		ID:            lastID,
		Worker:        e.Worker,
		Poster:        e.Poster,
		Reviewers:     append([]address{}, e.Reviewers...),
		ReviewerTrust: res.TrustBps,
		Points:        res.Points,
		ShareBps:      e.ShareBps,
		Amount:        e.Amount,
		Denom:         e.Denom,
		Title:         e.Title,
		Link:          e.Link,
		Ref:           e.Ref,
		Source:        src,
		SignedBy:      unsafe.OriginCaller(),
		Arbitrated:    e.Arbitrated,
		Height:        runtime.ChainHeight(),
		At:            time.Now(),
	}
	records.Set(idKey(rec.ID), rec)

	wp := getOrCreateProfile(e.Worker)
	wp.Records = append(wp.Records, rec.ID)
	addEarned(wp, e.Denom, e.Amount)
	touch(wp, rec.At)
	setScore(wp, wp.Score+rec.Points)

	seen := map[address]bool{}
	for _, r := range e.Reviewers {
		if seen[r] || r == e.Worker {
			continue
		}
		seen[r] = true
		rp := getOrCreateProfile(r)
		rp.Reviews = append(rp.Reviews, rec.ID)
		touch(rp, rec.At)
	}

	chain.Emit("GuildhallRecord",
		"id", strconv.FormatUint(rec.ID, 10),
		"worker", e.Worker.String(),
		"points", strconv.FormatInt(rec.Points, 10),
		"source", src,
		"ref", e.Ref,
	)
	return rec.ID
}

func validateEntry(e entry) error {
	if !e.Worker.IsValid() {
		return errors.New("reputation: invalid worker address")
	}
	if !e.Poster.IsValid() {
		return errors.New("reputation: invalid poster address")
	}
	if len(e.Reviewers) == 0 || len(e.Reviewers) > maxReviewers {
		return errors.New("reputation: a record needs 1..16 reviewers")
	}
	for _, r := range e.Reviewers {
		if !r.IsValid() {
			return errors.New("reputation: invalid reviewer address")
		}
	}
	if e.Amount < 0 {
		return errors.New("reputation: negative amount")
	}
	if len(e.Title) > maxTextLen || len(e.Link) > maxTextLen || len(e.Ref) > maxTextLen || len(e.Denom) > maxTextLen {
		return errors.New("reputation: field too long")
	}
	return nil
}

// ---------------------------------------------------------------------------
// Reading: the API other realms import.

// Score returns addr's current reputation score.
func Score(addr address) int64 {
	p := getProfile(addr)
	if p == nil {
		return 0
	}
	return p.Score
}

// Level returns a display name for addr's score band.
func Level(addr address) string {
	return trust.Level(Score(addr))
}

// HasScore reports whether addr's score is at least min.
func HasScore(addr address, min int64) bool {
	return Score(addr) >= min
}

// AssertScore panics unless addr's score is at least min. It is the one-line
// gate for realms that want reputation-weighted access.
func AssertScore(addr address, min int64) {
	if s := Score(addr); s < min {
		panic(ufmt.Sprintf("guildhall: reputation %d is below the required %d", s, min))
	}
}

// CompletedCount returns how many paid records addr has as a worker.
func CompletedCount(addr address) int {
	p := getProfile(addr)
	if p == nil {
		return 0
	}
	return len(p.Records)
}

// ReviewCount returns how many records addr has vouched for.
func ReviewCount(addr address) int {
	p := getProfile(addr)
	if p == nil {
		return 0
	}
	return len(p.Reviews)
}

// Earned returns the total addr has been paid in denom through records.
func Earned(addr address, denom string) int64 {
	p := getProfile(addr)
	if p == nil || p.earned == nil {
		return 0
	}
	v := p.earned.Get(denom)
	if v == nil {
		return 0
	}
	return v.(int64)
}

// IsSeed reports whether addr is a seed reviewer.
func IsSeed(addr address) bool {
	return seeds.Has(addr.String())
}

// IsWriter reports whether pkgPath may write records.
func IsWriter(pkgPath string) bool {
	return writers.Has(pkgPath)
}

// RecordCount returns the number of records ever written.
func RecordCount() int {
	return records.Size()
}

// ContributorCount returns the number of addresses with a positive score.
func ContributorCount() int {
	return leaderboard.Size()
}

// GetRecord returns a copy of the record with the given id.
func GetRecord(id uint64) (Record, bool) {
	r := getRecord(id)
	if r == nil {
		return Record{}, false
	}
	return copyRecord(r), true
}

// RecordsOf returns up to limit of addr's work records, newest first,
// skipping the first offset.
func RecordsOf(addr address, offset, limit int) []Record {
	p := getProfile(addr)
	if p == nil {
		return nil
	}
	return collect(p.Records, offset, limit)
}

// ReviewsOf returns up to limit of the records addr vouched for, newest first.
func ReviewsOf(addr address, offset, limit int) []Record {
	p := getProfile(addr)
	if p == nil {
		return nil
	}
	return collect(p.Reviews, offset, limit)
}

// Top returns the n highest scores, highest first. Ties are ordered by
// address.
func Top(n int) []Standing {
	var out []Standing
	leaderboard.Iterate("", "", func(_ string, v any) bool {
		addr := v.(address)
		out = append(out, Standing{Addr: addr, Score: Score(addr)})
		return len(out) >= n
	})
	return out
}

// Rank returns addr's 1-based leaderboard position, or 0 if unranked.
func Rank(addr address) int {
	p := getProfile(addr)
	if p == nil || p.Score <= 0 {
		return 0
	}
	key := boardKey(p.Score, addr)
	rank := 0
	leaderboard.Iterate("", key, func(_ string, _ any) bool {
		rank++
		return rank > maxRank
	})
	if rank > maxRank {
		return 0
	}
	return rank + 1
}

// Params returns the scoring parameters in force.
func Params() trust.Params {
	return params
}

// Admin returns the address allowed to curate seeds, writers and parameters.
func Admin() address {
	return admin.Owner()
}

// ---------------------------------------------------------------------------
// Governance

//
// Guildhall governs itself: the admin, and nobody else, curates seeds,
// writers, parameters and voids. No outside realm has authority here. Hand
// the role to a multisig with TransferAdmin to share it.

// AddSeed marks addr as a seed reviewer with full trust.
func AddSeed(cur realm, addr address) {
	assertAdmin(cur)
	addSeed(addr)
}

// RemoveSeed revokes addr's seed status. Existing records keep the points
// they were awarded; only future reviews are affected.
func RemoveSeed(cur realm, addr address) {
	assertAdmin(cur)
	removeSeed(addr)
}

// AddWriter allows another realm to write records.
func AddWriter(cur realm, pkgPath string) {
	assertAdmin(cur)
	addWriter(pkgPath)
}

// RemoveWriter revokes a realm's right to write records.
func RemoveWriter(cur realm, pkgPath string) {
	assertAdmin(cur)
	removeWriter(pkgPath)
}

// SetParams changes the scoring rules for future records.
func SetParams(cur realm, base, trustThreshold, trustFloorBps, selfFundedFactorBps int64) {
	assertAdmin(cur)
	setParams(newParams(base, trustThreshold, trustFloorBps, selfFundedFactorBps))
}

// VoidRecord cancels a fraudulent record and removes its points from the
// worker. Trust the worker lent to others while holding those points is not
// unwound; voiding is for correcting abuse, not rewriting history.
func VoidRecord(cur realm, id uint64, reason string) {
	assertAdmin(cur)
	checkVoid(id, reason)
	voidRecord(id, reason)
}

// TransferAdmin hands the admin key to another address, such as a multisig.
func TransferAdmin(cur realm, newAdmin address) {
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err.Error())
	}
}

// RenounceAdmin gives up the admin key for good. Nothing can curate
// reputation afterwards: seeds, writers and parameters are frozen and no
// record can be voided. Prefer TransferAdmin unless that is the intent.
func RenounceAdmin(cur realm) {
	if err := admin.DropOwnership(0, cur); err != nil {
		panic(err.Error())
	}
}

func addSeed(addr address) {
	if !addr.IsValid() {
		panic("reputation: invalid address")
	}
	seeds.Set(addr.String(), struct{}{})
	chain.Emit("GuildhallSeedAdded", "addr", addr.String())
}

func removeSeed(addr address) {
	if _, ok := seeds.Remove(addr.String()); !ok {
		panic("reputation: not a seed")
	}
	chain.Emit("GuildhallSeedRemoved", "addr", addr.String())
}

func addWriter(pkgPath string) {
	if pkgPath == "" {
		panic("reputation: empty pkgpath")
	}
	writers.Set(pkgPath, struct{}{})
	chain.Emit("GuildhallWriterAdded", "pkgpath", pkgPath)
}

func removeWriter(pkgPath string) {
	if _, ok := writers.Remove(pkgPath); !ok {
		panic("reputation: not a writer")
	}
	chain.Emit("GuildhallWriterRemoved", "pkgpath", pkgPath)
}

func newParams(base, trustThreshold, trustFloorBps, selfFundedFactorBps int64) trust.Params {
	p := trust.Params{
		Base:                base,
		TrustThreshold:      trustThreshold,
		TrustFloorBps:       trustFloorBps,
		SelfFundedFactorBps: selfFundedFactorBps,
	}
	if err := p.Validate(); err != nil {
		panic(err.Error())
	}
	return p
}

func setParams(p trust.Params) {
	params = p
	chain.Emit("GuildhallParamsChanged")
}

func checkVoid(id uint64, reason string) {
	r := getRecord(id)
	if r == nil {
		panic("reputation: unknown record")
	}
	if r.Voided {
		panic("reputation: record already voided")
	}
	if reason == "" || len(reason) > maxTextLen {
		panic("reputation: a reason of 1..300 bytes is required")
	}
}

func voidRecord(id uint64, reason string) {
	checkVoid(id, reason)
	r := getRecord(id)
	r.Voided = true
	r.VoidReason = reason
	p := getProfile(r.Worker)
	setScore(p, p.Score-r.Points)
	chain.Emit("GuildhallRecordVoided", "id", strconv.FormatUint(id, 10), "reason", reason)
}

func assertAdmin(cur realm) {
	admin.AssertOwnedBy(cur.Previous().Address())
}

// ---------------------------------------------------------------------------
// Internals

func getProfile(addr address) *Profile {
	v := profiles.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*Profile)
}

func getOrCreateProfile(addr address) *Profile {
	if p := getProfile(addr); p != nil {
		return p
	}
	p := &Profile{Addr: addr, earned: avl.NewTree()}
	profiles.Set(addr.String(), p)
	return p
}

func getRecord(id uint64) *Record {
	v := records.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*Record)
}

func touch(p *Profile, at time.Time) {
	if p.First.IsZero() {
		p.First = at
	}
	p.Last = at
}

func addEarned(p *Profile, denom string, amount int64) {
	cur := int64(0)
	if v := p.earned.Get(denom); v != nil {
		cur = v.(int64)
	}
	p.earned.Set(denom, cur+amount)
}

func setScore(p *Profile, score int64) {
	if p.Score > 0 {
		leaderboard.Remove(boardKey(p.Score, p.Addr))
	}
	if score < 0 {
		score = 0
	}
	p.Score = score
	if score > 0 {
		leaderboard.Set(boardKey(score, p.Addr), p.Addr)
	}
}

// boardKey sorts higher scores first under avl's ascending iteration.
func boardKey(score int64, addr address) string {
	return pad(9223372036854775807-score, 19) + ":" + addr.String()
}

func idKey(id uint64) string {
	return pad(int64(id), 12)
}

func pad(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func collect(ids []uint64, offset, limit int) []Record {
	var out []Record
	if offset < 0 {
		offset = 0
	}
	for i := len(ids) - 1 - offset; i >= 0 && len(out) < limit; i-- {
		if r := getRecord(ids[i]); r != nil {
			out = append(out, copyRecord(r))
		}
	}
	return out
}

func copyRecord(r *Record) Record {
	c := *r
	c.Reviewers = append([]address{}, r.Reviewers...)
	c.ReviewerTrust = append([]int64{}, r.ReviewerTrust...)
	return c
}
