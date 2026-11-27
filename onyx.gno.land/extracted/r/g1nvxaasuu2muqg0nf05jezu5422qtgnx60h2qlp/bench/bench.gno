package bench

import (
	"chain/runtime"
	"strconv"
	"time"
	"unicode/utf8"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/commitreveal"
	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
)

const (
	secondsPerDay        = 86400
	quickRoundIndexWidth = 10
	maxQuickRoundSeq     = 9999999999
)

// EnsureTodayChallenges seeds the two daily rounds once per UTC day.
func EnsureTodayChallenges(cur realm) {
	ensureDayChallenges(currentDayID(), runtime.ChainHeight(), time.Now().Unix())
}

func currentDayID() int64 {
	return time.Now().Unix() / secondsPerDay
}

func dailyRoundPrefix(dayID int64) string {
	return "D:" + strconv.FormatInt(dayID, 10) + ":"
}

func ensureDayChallenges(dayID, height, nowUnix int64) {
	prefix := dailyRoundPrefix(dayID)
	classicKey := prefix + "wca"
	if challenges.Has(classicKey) {
		return
	}
	const classicRuleKey = "wca_obtm"
	classicRule, _ := cube3x3.BuiltinRule(classicRuleKey)
	twistedRule := cube3x3.DailyTwistedRule(dayID)
	classic := newChallenge(classicKey, "daily_classic", classicRuleKey, classicRule, height, nowUnix)
	twisted := newChallenge(prefix+"twisted", "daily_twisted", twistedRule.ID(), twistedRule, height, nowUnix)
	for _, c := range []*challengeRecord{classic, twisted} {
		c.CommitDeadline = (dayID + 1) * secondsPerDay
		c.RevealDeadline = (dayID + 2) * secondsPerDay
		challenges.Set(c.RoundKey, c)
	}
}

func newChallenge(roundKey, kind, ruleKey string, rule cube3x3.ConstraintRule, height, nowUnix int64) *challengeRecord {
	seed := computeRoundSeed(roundKey, height, nowUnix)
	moves, err := cube3x3.ScrambleForRule(seed, rule.ID(), rule.AllowedMoves())
	if err != nil {
		panic(ErrRuleViolation)
	}
	return &challengeRecord{
		RoundKey:      roundKey,
		Kind:          kind,
		RuleKey:       ruleKey,
		ScrambleMoves: moves,
		ScrambleStr:   cube3x3.FormatMoves(moves),
		ScrambleState: cube3x3.ApplyMoves(cube3x3.SolvedCube(), moves),
	}
}

func requireChallenge(roundKey string) *challengeRecord {
	c, ok := challenges.Get(roundKey).(*challengeRecord)
	if !ok {
		panic(ErrRoundNotFound)
	}
	return c
}

// Commit stores or updates the caller's digest during the commit window.
func Commit(cur realm, roundKey, commitHash string) {
	if !commitreveal.IsValidHashHex(commitHash) {
		panic(ErrHashMismatch)
	}
	nowUnix := time.Now().Unix()
	c, ok := challenges.Get(roundKey).(*challengeRecord)
	if !ok {
		dayID := nowUnix / secondsPerDay
		prefix := dailyRoundPrefix(dayID)
		if roundKey != prefix+"wca" && roundKey != prefix+"twisted" {
			panic(ErrRoundNotFound)
		}
		ensureDayChallenges(dayID, runtime.ChainHeight(), nowUnix)
		c = requireChallenge(roundKey)
	}
	if computePhase(c, nowUnix) != "commit_open" {
		panic(ErrPhaseClosed)
	}
	caller := cur.Previous().Address().String()
	entryKey := roundKey + "|" + caller
	rec, exists := commits.Get(entryKey).(commitreveal.Record)
	rec.CommitHash = commitHash
	rec.CommittedAt = nowUnix
	rec.UpdatedCount++
	commits.Set(entryKey, rec)
	if !exists {
		c.CommitCount++
		c.UnrevealedCount++
	}
}

// Reveal verifies a commitment with the default human solve metadata.
func Reveal(cur realm, roundKey, rawMoves, salt, notes string) {
	revealInternal(cur, roundKey, rawMoves, salt, notes, "human", "")
}

// RevealWithMeta verifies a commitment and records the caller's solve metadata.
func RevealWithMeta(cur realm, roundKey, rawMoves, salt, notes, modeTag, agentModel string) {
	revealInternal(cur, roundKey, rawMoves, salt, notes, modeTag, agentModel)
}

func revealInternal(cur realm, roundKey, rawMoves, salt, notes, modeTag, agentModel string) {
	c := requireChallenge(roundKey)
	nowUnix := time.Now().Unix()
	if computePhase(c, nowUnix) != "reveal_open" {
		panic(ErrPhaseClosed)
	}
	if !commitreveal.IsValidSalt(salt) {
		panic(ErrInvalidSalt)
	}
	if len(notes) > MaxNotesBytes {
		panic(ErrNotesTooLong)
	}
	mode, ok := normalizeModeTag(modeTag)
	if !ok {
		panic(ErrInvalidModeTag)
	}
	model, ok := validateAgentModel(agentModel)
	if !ok {
		panic(ErrInvalidAgentModel)
	}
	caller := cur.Previous().Address().String()
	entryKey := roundKey + "|" + caller
	rec, ok := commits.Get(entryKey).(commitreveal.Record)
	if !ok || submissions.Has(entryKey) {
		panic(ErrNoCommit)
	}
	canonical, moves, err := cube3x3.Canonicalize(rawMoves)
	if err != nil {
		panic(err.Error())
	}
	if err := commitreveal.VerifyReveal(rec, Domain, roundKey, caller, canonical, salt); err != nil {
		panic(ErrHashMismatch)
	}
	rule, ok := resolveRule(c.RuleKey)
	if !ok {
		panic(ErrRuleNotFound)
	}
	res := cube3x3.VerifyCanonicalMoves(c.ScrambleMoves, canonical, moves, rule)
	if !res.Valid {
		panic(res.ErrorCode + ": " + res.ErrorMessage)
	}

	commits.Remove(entryKey)
	c.UnrevealedCount--
	c.RevealCount++
	sub := &submissionRecord{
		Solver:         caller,
		CanonicalMoves: canonical,
		OBTM:           res.OBTM,
		QTM:            res.QTM,
		RevealedAt:     nowUnix,
		Notes:          notes,
		ModeTag:        mode,
		AgentModel:     model,
		Phases:         *res.Phases,
	}
	submissions.Set(entryKey, sub)
	leaderboards, _ = leaderboards.Set(leaderboardKey(roundKey, sub), caller)
}

// StartQuickRound creates a round with consecutive commit and reveal windows.
func StartQuickRound(cur realm, ruleKey string, commitSeconds, revealSeconds int64) string {
	if commitSeconds < MinQuickWindowSeconds || commitSeconds > MaxQuickWindowSeconds ||
		revealSeconds < MinQuickWindowSeconds || revealSeconds > MaxQuickWindowSeconds {
		panic(ErrWindowRange)
	}
	rule, ok := resolveRule(ruleKey)
	if !ok {
		panic(ErrRuleNotFound)
	}
	if quickSeq >= maxQuickRoundSeq {
		panic(ErrRuleViolation)
	}
	nextSeq := quickSeq + 1
	roundKey := "Q:" + strconv.FormatUint(nextSeq, 10)
	nowUnix := time.Now().Unix()
	c := newChallenge(roundKey, "quick", ruleKey, rule, runtime.ChainHeight(), nowUnix)
	c.Creator = cur.Previous().Address().String()
	c.CommitWindowSeconds = commitSeconds
	c.CommitDeadline = nowUnix + commitSeconds
	c.RevealDeadline = c.CommitDeadline + revealSeconds
	quickSeq = nextSeq
	challenges.Set(roundKey, c)
	quickRounds.Set(padInt64(int64(nextSeq), quickRoundIndexWidth), roundKey)
	return roundKey
}

// PruneExpiredCommits removes one batch of unrevealed commits from a finalized round.
func PruneExpiredCommits(cur realm, roundKey string, maxDelete int) int {
	c := requireChallenge(roundKey)
	if !commitreveal.CanPrune(c.RevealDeadline, time.Now().Unix()) {
		panic(ErrPhaseClosed)
	}
	if maxDelete <= 0 {
		maxDelete = DefaultPruneLimit
	} else if maxDelete > MaxPruneLimit {
		maxDelete = MaxPruneLimit
	}

	prefix := roundKey + "|"
	keys := make([]string, 0, maxDelete)
	commits.Iterate(prefix, prefixRangeEnd(prefix), func(key string, _ any) bool {
		keys = append(keys, key)
		return len(keys) == maxDelete
	})
	for _, key := range keys {
		commits.Remove(key)
	}
	if len(keys) > 0 {
		c.UnrevealedCount -= len(keys)
	}
	return len(keys)
}

// RegisterRule saves a realm-owned rule and caches its display metadata.
func RegisterRule(cur realm, rule cube3x3.ConstraintRule) string {
	owner := cur.Previous().PkgPath()
	if rule == nil || owner == "" {
		panic(ErrRuleViolation)
	}
	id := rule.ID()
	if !validRuleID(id) {
		panic(ErrRuleViolation)
	}
	if _, builtin := cube3x3.BuiltinRule(id); builtin {
		panic(ErrRuleViolation)
	}
	key := owner + ":" + id
	if customRules.Has(key) {
		panic(ErrRuleViolation)
	}
	title, desc := rule.Title(), rule.Description()
	if title == "" || utf8.RuneCountInString(title) > 80 || utf8.RuneCountInString(desc) > 240 {
		panic(ErrRuleViolation)
	}
	if _, err := cube3x3.GenerateSubgroupScramble([32]byte{}, rule.AllowedMoves(), 5); err != nil {
		panic(ErrRuleViolation)
	}
	if len(rule.TargetAlg()) > 30 {
		panic(ErrRuleViolation)
	}
	// Rules may reject the empty trace with an error. A panic aborts registration.
	_ = rule.Validate(cube3x3.MoveTrace{})
	customRules.Set(key, registeredRule{Key: key, Rule: rule, Title: title, Description: desc})
	return key
}

func validRuleID(id string) bool {
	if len(id) == 0 || len(id) > 48 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !('a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}
