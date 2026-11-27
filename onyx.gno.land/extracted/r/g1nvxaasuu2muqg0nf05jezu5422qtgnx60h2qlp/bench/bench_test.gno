package bench

import (
	"crypto/sha256"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/commitreveal"
	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	benchTestTime  int64 = 1795651200 // Start of day 20783 UTC.
	benchTestSalt        = "0011223344556677"
	benchTestOwner       = "gno.land/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/customrule_demo"
	benchTestSolve       = "R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' F'"
)

func isolateBenchTestState() func() {
	oldChallenges, oldCommits, oldSubmissions := challenges, commits, submissions
	oldLeaderboards, oldQuickRounds, oldRules, oldSeq := leaderboards, quickRounds, customRules, quickSeq
	challenges, commits, submissions = avl.NewTree(), avl.NewTree(), avl.NewTree()
	leaderboards, quickRounds, customRules, quickSeq = nil, avl.NewTree(), avl.NewTree(), 0
	return func() {
		challenges, commits, submissions = oldChallenges, oldCommits, oldSubmissions
		leaderboards, quickRounds, customRules, quickSeq = oldLeaderboards, oldQuickRounds, oldRules, oldSeq
	}
}

func setBenchTestContext(now, height int64, caller address) {
	ctx := testing.GetContext()
	ctx.Time = time.Unix(now, 0)
	ctx.Height = height
	ctx.OriginCaller = caller
	ctx.CurrentRealm = testing.NewUserRealm(caller)
	testing.SetContext(ctx)
}

func TestEnsureTodayChallengesIsIdempotent(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	keeper := testutils.TestAddress("keeper")
	setBenchTestContext(benchTestTime, 42, keeper)
	EnsureTodayChallenges(cross(cur))
	classic, classicOK := challenges.Get("D:20783:wca").(*challengeRecord)
	twisted, twistedOK := challenges.Get("D:20783:twisted").(*challengeRecord)
	if !classicOK || !twistedOK {
		t.Fatal("both daily rounds must be seeded")
	}
	uassert.Equal(t, "wca_obtm", classic.RuleKey)
	uassert.Equal(t, "no_half_turns", twisted.RuleKey)
	uassert.Equal(t, "daily_classic", classic.Kind)
	uassert.Equal(t, "daily_twisted", twisted.Kind)
	for _, c := range []*challengeRecord{classic, twisted} {
		uassert.Equal(t, "", c.Creator)
		uassert.Equal(t, int64(1795737600), c.CommitDeadline)
		uassert.Equal(t, int64(1795824000), c.RevealDeadline)
		uassert.True(t, len(c.ScrambleMoves) > 0)
		uassert.Equal(t, cube3x3.FormatMoves(c.ScrambleMoves), c.ScrambleStr)
		uassert.True(t, cube3x3.ApplyMoves(cube3x3.SolvedCube(), c.ScrambleMoves) == c.ScrambleState)
	}
	classicScramble, twistedScramble := classic.ScrambleStr, twisted.ScrambleStr
	seeded := GetTodayJSON()
	setBenchTestContext(benchTestTime+5, 43, keeper)
	EnsureTodayChallenges(cross(cur))
	uassert.Equal(t, strings.Replace(seeded, `"nowUnix":1795651200`, `"nowUnix":1795651205`, 1), GetTodayJSON())
	uassert.True(t, classic == challenges.Get("D:20783:wca"))
	uassert.True(t, twisted == challenges.Get("D:20783:twisted"))
	uassert.Equal(t, classicScramble, classic.ScrambleStr)
	uassert.Equal(t, twistedScramble, twisted.ScrambleStr)
}

func TestCommitLazyInitAndOverwrite(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "D:20783:twisted"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	hash := strings.Repeat("a", 64)
	uassert.AbortsWithMessage(t, cur, ErrHashMismatch, func() {
		Commit(cross(cur), key, strings.ToUpper(hash))
	})
	uassert.False(t, challenges.Has(key))
	uassert.AbortsWithMessage(t, cur, ErrRoundNotFound, func() {
		Commit(cross(cur), "D:20784:wca", hash)
	})
	Commit(cross(cur), key, hash)
	c, ok := challenges.Get(key).(*challengeRecord)
	if !ok {
		t.Fatal("Commit must seed today's requested round")
	}
	uassert.True(t, challenges.Has("D:20783:wca"))
	entry := key + "|" + alice.String()
	assertBenchCommit(t, entry, commitreveal.Record{CommitHash: hash, CommittedAt: benchTestTime, UpdatedCount: 1})
	setBenchTestContext(benchTestTime+5, 43, alice)
	replacement := strings.Repeat("b", 64)
	Commit(cross(cur), key, replacement)
	assertBenchCommit(t, entry, commitreveal.Record{CommitHash: replacement, CommittedAt: benchTestTime + 5, UpdatedCount: 2})
	uassert.Equal(t, 1, c.CommitCount)
	uassert.Equal(t, 1, c.UnrevealedCount)
	setBenchTestContext(c.CommitDeadline, 44, alice)
	uassert.AbortsWithMessage(t, cur, ErrPhaseClosed, func() {
		Commit(cross(cur), key, hash)
	})
}

func assertBenchCommit(t *testing.T, entry string, want commitreveal.Record) {
	t.Helper()
	if got, ok := commits.Get(entry).(commitreveal.Record); !ok || got != want {
		t.Errorf("commit %q = %+v (present: %t), want %+v", entry, got, ok, want)
	}
}

func seedBenchRevealChallenge(key string) {
	challenges.Set(key, &challengeRecord{
		RoundKey: key, Kind: "quick", RuleKey: "wca_obtm",
		ScrambleMoves:  []cube3x3.Move{{Base: cube3x3.F, Mod: 1}},
		CommitDeadline: benchTestTime + 30, RevealDeadline: benchTestTime + 60,
	})
}

func TestRevealDefaultsToHumanAndReplacesCommit(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:100"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	seedBenchRevealChallenge(key)
	Commit(cross(cur), key, commitreveal.ComputeHash(Domain, key, alice.String(), benchTestSolve, benchTestSalt))
	setBenchTestContext(benchTestTime+30, 48, alice)
	rawMoves := "  " + strings.ReplaceAll(benchTestSolve, " ", "\t") + "  "
	dryRun := VerifyDryRunJSON(key, rawMoves)
	assertBenchContains(t, dryRun, `"valid":true,"errorCode":"","errorMessage":""`,
		`"canonicalMoves":"`+benchTestSolve+`","obtm":25,"qtm":25,"solved":true,"phases":{`)
	const phaseKey = `,"phases":`
	phaseStart := strings.Index(dryRun, phaseKey)
	if phaseStart < 0 {
		t.Fatalf("dry run missing phase report: %s", dryRun)
	}
	Reveal(cross(cur), key, rawMoves, benchTestSalt, "first solve")
	assertBenchContains(t, GetLeaderboardJSON(key, 1),
		`"obtm":25,"qtm":25,"revealedAt":1795651230,"moves":"`+benchTestSolve+`"`,
		`"modeTag":"human","agentModel":""`+dryRun[phaseStart:]+`]}`)
	entry := key + "|" + alice.String()
	s, ok := submissions.Get(entry).(*submissionRecord)
	if !ok {
		t.Fatal("Reveal must store the accepted submission")
	}
	uassert.Equal(t, alice.String(), s.Solver)
	uassert.Equal(t, benchTestSolve, s.CanonicalMoves)
	uassert.Equal(t, "first solve", s.Notes)
	uassert.Equal(t, "human", s.ModeTag)
	uassert.Equal(t, "", s.AgentModel)
	uassert.Equal(t, 25, s.OBTM)
	uassert.Equal(t, 25, s.QTM)
	uassert.Equal(t, benchTestTime+30, s.RevealedAt)
	uassert.True(t, len(s.Phases.Segments) > 0)
	_, solver, found := leaderboards.Get("Q:100|0025|0025|001795651230|" + alice.String())
	uassert.True(t, found)
	uassert.Equal(t, alice.String(), solver)
	uassert.False(t, commits.Has(entry))
	c := challenges.Get(key).(*challengeRecord)
	uassert.Equal(t, 1, c.CommitCount)
	uassert.Equal(t, 1, c.RevealCount)
	uassert.Equal(t, 0, c.UnrevealedCount)
	uassert.AbortsWithMessage(t, cur, ErrNoCommit, func() {
		Reveal(cross(cur), key, benchTestSolve, benchTestSalt, "")
	})
	commits.Set(entry, commitreveal.Record{})
	uassert.AbortsWithMessage(t, cur, ErrNoCommit, func() {
		Reveal(cross(cur), key, benchTestSolve, benchTestSalt, "")
	})
}

func TestRevealWithMetaValidatesBeforeMutating(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:101"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	seedBenchRevealChallenge(key)
	const wrongTarget = "R"
	Commit(cross(cur), key, commitreveal.ComputeHash(Domain, key, alice.String(), wrongTarget, benchTestSalt))
	setBenchTestContext(benchTestTime+30, 48, alice)
	for _, tc := range []struct {
		round, moves, salt, notes, mode, model, want string
	}{
		{"Q:missing", "M", "", "", "", "", ErrRoundNotFound},
		{key, "M", "short", strings.Repeat("a", 281), "robot", "\n", ErrInvalidSalt},
		{key, "M", benchTestSalt, strings.Repeat("é", 141), "robot", "\n", ErrNotesTooLong},
		{key, "M", benchTestSalt, "", "robot", "\n", ErrInvalidModeTag},
		{key, "M", benchTestSalt, "", "ai", "\n", ErrInvalidAgentModel},
		{key, "M", benchTestSalt, "", "ai", strings.Repeat("a", 65), ErrInvalidAgentModel},
		{key, "M", benchTestSalt, "", "ai", "", ErrInvalidNotation},
		{key, strings.Repeat("R", 513), benchTestSalt, "", "ai", "", ErrInputTooLong},
		{key, benchTestSolve, benchTestSalt, "", "ai", "", ErrHashMismatch},
		{key, wrongTarget, benchTestSalt, "", "ai", "", "ERR_NOT_SOLVED: These moves do not reach the target cube state."},
	} {
		uassert.AbortsWithMessage(t, cur, tc.want, func() {
			RevealWithMeta(cross(cur), tc.round, tc.moves, tc.salt, tc.notes, tc.mode, tc.model)
		})
	}
	entry := key + "|" + alice.String()
	uassert.True(t, commits.Has(entry))
	uassert.False(t, submissions.Has(entry))
	c := challenges.Get(key).(*challengeRecord)
	uassert.Equal(t, 1, c.UnrevealedCount)
	uassert.Equal(t, 0, c.RevealCount)

	bob := testutils.TestAddress("bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, ErrNoCommit, func() {
		RevealWithMeta(cross(cur), key, "M", benchTestSalt, "", "ai", "")
	})
	setBenchTestContext(benchTestTime, 42, bob)
	Commit(cross(cur), key, commitreveal.ComputeHash(Domain, key, bob.String(), benchTestSolve, benchTestSalt))
	setBenchTestContext(benchTestTime+30, 48, bob)
	notes := strings.Repeat("é", 140)
	RevealWithMeta(cross(cur), key, benchTestSolve, benchTestSalt, notes, "ai", "  CustomSolver  ")
	s, ok := submissions.Get(key + "|" + bob.String()).(*submissionRecord)
	if !ok {
		t.Fatal("RevealWithMeta must store the accepted submission")
	}
	uassert.Equal(t, notes, s.Notes)
	uassert.Equal(t, "ai", s.ModeTag)
	uassert.Equal(t, "CustomSolver", s.AgentModel)
	uassert.True(t, commits.Has(entry))
	uassert.Equal(t, 1, c.UnrevealedCount)
	uassert.Equal(t, 1, c.RevealCount)
}

func TestDryRunAndRevealRejectTheSameInvalidSolves(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	alice := testutils.TestAddress("alice")
	for _, tc := range []struct {
		key, rule, moves, code, message string
	}{
		{"Q:1", "wca_obtm", "F'", "ERR_TRIVIAL_INVERSE", "This solution simply reverses the scramble. Find an original solve instead."},
		{"Q:2", "no_fb", benchTestSolve, "ERR_RULE_VIOLATION", "Only Right (R), Up (U), Left (L), and Down (D) face turns are allowed in this challenge."},
	} {
		setBenchTestContext(benchTestTime, 42, alice)
		seedBenchRevealChallenge(tc.key)
		requireChallenge(tc.key).RuleKey = tc.rule
		hash := commitreveal.ComputeHash(Domain, tc.key, alice.String(), tc.moves, benchTestSalt)
		Commit(cross(cur), tc.key, hash)
		setBenchTestContext(benchTestTime+30, 48, alice)
		before := GetCommitStatusJSON(tc.key, alice.String())
		assertBenchContains(t, VerifyDryRunJSON(tc.key, tc.moves),
			`"valid":false,"errorCode":"`+tc.code+`","errorMessage":"`+tc.message+`"`, `"solved":true,"phases":null`)
		uassert.AbortsWithMessage(t, cur, tc.code+": "+tc.message, func() {
			Reveal(cross(cur), tc.key, tc.moves, benchTestSalt, "")
		})
		uassert.AbortsWithMessage(t, cur, tc.code+": "+tc.message, func() {
			RevealWithMeta(cross(cur), tc.key, tc.moves, benchTestSalt, "", "assisted", "Gemini 4")
		})
		uassert.Equal(t, before, GetCommitStatusJSON(tc.key, alice.String()))
		uassert.Equal(t, `{"roundKey":"`+tc.key+`","phase":"reveal_open","totalRevealed":0,"rows":[]}`,
			GetLeaderboardJSON(tc.key, 5))
	}
}

func TestStartQuickRoundEnforcesWindowsAndSeedsNextKey(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	for _, windows := range [][2]int64{{29, 30}, {3601, 30}, {30, 29}, {30, 3601}} {
		uassert.AbortsWithMessage(t, cur, ErrWindowRange, func() {
			StartQuickRound(cross(cur), "wca_obtm", windows[0], windows[1])
		})
	}
	uassert.AbortsWithMessage(t, cur, ErrRuleNotFound, func() {
		StartQuickRound(cross(cur), "bogus", 30, 3600)
	})
	const badKey = benchTestOwner + ":bad_axes"
	customRules.Set(badKey, registeredRule{Rule: benchTestRule{id: "bad_axes", singleAxis: true}})
	uassert.AbortsWithMessage(t, cur, ErrRuleViolation, func() {
		StartQuickRound(cross(cur), badKey, 30, 3600)
	})
	key := StartQuickRound(cross(cur), "wca_obtm", 30, 3600)
	uassert.Equal(t, "Q:1", key)
	c, ok := challenges.Get(key).(*challengeRecord)
	if !ok {
		t.Fatal("StartQuickRound must store the new round")
	}
	uassert.Equal(t, "Q:1", c.RoundKey)
	uassert.Equal(t, "quick", c.Kind)
	uassert.Equal(t, "wca_obtm", c.RuleKey)
	uassert.Equal(t, alice.String(), c.Creator)
	uassert.Equal(t, int64(30), c.CommitWindowSeconds)
	uassert.Equal(t, benchTestTime+30, c.CommitDeadline)
	uassert.Equal(t, benchTestTime+3630, c.RevealDeadline)
	uassert.Equal(t, key, quickRounds.Get("0000000001"))
	seed := sha256.Sum256([]byte("colorado/v1|Q:1|42|1795651200"))
	uassert.Equal(t, cube3x3.FormatMoves(cube3x3.GenerateWCAScramble(seed)), c.ScrambleStr)
	uassert.True(t, cube3x3.ApplyMoves(cube3x3.SolvedCube(), c.ScrambleMoves) == c.ScrambleState)
}

func TestStartQuickRoundPreservesIndexWidth(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	setBenchTestContext(benchTestTime, 42, testutils.TestAddress("alice"))
	quickSeq = 9999999998
	uassert.Equal(t, "Q:9999999999", StartQuickRound(cross(cur), "wca_obtm", 30, 30))
	uassert.Equal(t, "Q:9999999999", quickRounds.Get("9999999999"))
	uassert.AbortsWithMessage(t, cur, ErrRuleViolation, func() {
		StartQuickRound(cross(cur), "wca_obtm", 30, 30)
	})
	uassert.Equal(t, uint64(9999999999), quickSeq)
	uassert.False(t, challenges.Has("Q:10000000000"))
}

func TestPruneExpiredCommitsBatchesAtRevealDeadline(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:2"
	caller := testutils.TestAddress("janitor")
	setBenchTestContext(benchTestTime, 42, caller)
	seedBenchRevealChallenge(key)
	c := challenges.Get(key).(*challengeRecord)
	const total = 153
	c.CommitCount, c.UnrevealedCount = total, total
	for i := 0; i < total; i++ {
		commits.Set(key+"|g1test"+strconv.Itoa(i), commitreveal.Record{})
	}
	const other = "Q:20|g1test0"
	commits.Set(other, commitreveal.Record{})
	uassert.AbortsWithMessage(t, cur, ErrPhaseClosed, func() {
		PruneExpiredCommits(cross(cur), key, 1)
	})
	setBenchTestContext(c.RevealDeadline-1, 53, caller)
	uassert.AbortsWithMessage(t, cur, ErrRoundNotFound, func() {
		PruneExpiredCommits(cross(cur), "Q:99", 1)
	})
	uassert.AbortsWithMessage(t, cur, ErrPhaseClosed, func() {
		PruneExpiredCommits(cross(cur), key, 1)
	})
	uassert.Equal(t, total, c.UnrevealedCount)
	setBenchTestContext(c.RevealDeadline, 54, caller)
	uassert.Equal(t, 50, PruneExpiredCommits(cross(cur), key, 0))
	uassert.Equal(t, 103, c.UnrevealedCount)
	uassert.Equal(t, 100, PruneExpiredCommits(cross(cur), key, 200))
	uassert.Equal(t, 3, c.UnrevealedCount)
	uassert.Equal(t, 2, PruneExpiredCommits(cross(cur), key, 2))
	assertBenchContains(t, GetChallengeJSON(key), `"unrevealedCount":1`)
	uassert.Equal(t, 1, PruneExpiredCommits(cross(cur), key, -1))
	uassert.Equal(t, 0, PruneExpiredCommits(cross(cur), key, 1))
	assertBenchContains(t, GetChallengeJSON(key), `"unrevealedCount":0`)
	uassert.Equal(t, total, c.CommitCount)
	uassert.Equal(t, 1, commits.Size())
	uassert.True(t, commits.Has(other))
}

type benchTestRule struct {
	id, title, desc string
	singleAxis      bool
	targetLength    int
	abortValidation bool
}

func (r benchTestRule) ID() string          { return r.id }
func (r benchTestRule) Title() string       { return r.title }
func (r benchTestRule) Description() string { return r.desc }
func (r benchTestRule) AllowedMoves() []cube3x3.Move {
	moves := []cube3x3.Move{{Base: cube3x3.R, Mod: 1}}
	if !r.singleAxis {
		moves = append(moves, cube3x3.Move{Base: cube3x3.U, Mod: 1})
	}
	return moves
}
func (r benchTestRule) TargetAlg() []cube3x3.Move { return make([]cube3x3.Move, r.targetLength) }
func (r benchTestRule) Validate(cube3x3.MoveTrace) error {
	if r.abortValidation {
		panic("test rule aborts on validation")
	}
	return errors.New("empty trace is not a solve")
}

func TestRegisterRuleRejectsInvalidRulesAndCachesMetadata(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	good := benchTestRule{id: "Example_1-v2", title: strings.Repeat("é", 80), desc: strings.Repeat("é", 240)}
	testing.SetOriginCaller(testutils.TestAddress("alice"))
	uassert.AbortsWithMessage(t, cur, ErrRuleViolation, func() {
		RegisterRule(cross(cur), good)
	})
	testing.SetRealm(testing.NewCodeRealm(benchTestOwner))
	for _, rule := range []cube3x3.ConstraintRule{
		nil,
		benchTestRule{id: "", title: good.title},
		benchTestRule{id: "bad:id", title: good.title},
		benchTestRule{id: "with space", title: good.title},
		benchTestRule{id: strings.Repeat("a", 49), title: good.title},
		benchTestRule{id: "empty_title"},
		benchTestRule{id: "long_title", title: strings.Repeat("a", 81)},
		benchTestRule{id: "long_desc", title: good.title, desc: strings.Repeat("a", 241)},
		benchTestRule{id: "no_fb", title: good.title},
		benchTestRule{id: "one_axis", title: good.title, singleAxis: true},
		benchTestRule{id: "long_target", title: good.title, targetLength: 31},
	} {
		uassert.AbortsWithMessage(t, cur, ErrRuleViolation, func() {
			RegisterRule(cross(cur), rule)
		})
	}
	uassert.AbortsWithMessage(t, cur, "test rule aborts on validation", func() {
		RegisterRule(cross(cur), benchTestRule{id: "abort", title: good.title, abortValidation: true})
	})
	uassert.Equal(t, 0, customRules.Size())
	key := RegisterRule(cross(cur), good)
	uassert.Equal(t, benchTestOwner+":Example_1-v2", key)
	entry, ok := customRules.Get(key).(registeredRule)
	if !ok {
		t.Fatal("RegisterRule must store the custom rule with cached metadata")
	}
	uassert.Equal(t, key, entry.Key)
	uassert.Equal(t, good.title, entry.Title)
	uassert.Equal(t, good.desc, entry.Description)
	uassert.Equal(t, good.id, entry.Rule.ID())
	replacement := benchTestRule{id: good.id, title: "Replacement"}
	uassert.AbortsWithMessage(t, cur, ErrRuleViolation, func() {
		RegisterRule(cross(cur), replacement)
	})
	uassert.Equal(t, good.title, customRules.Get(key).(registeredRule).Title)

	creator := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, creator)
	round := StartQuickRound(cross(cur), key, 30, 30)
	assertBenchContains(t, GetChallengeJSON(round), `"roundKey":"Q:1","kind":"quick","creator":"`+creator.String()+`"`,
		`"ruleKey":"`+key+`","ruleTitle":"`+good.title+`"`)
	assertBenchContains(t, GetTodayJSON(), `"ruleKey":"`+key+`","ruleTitle":"`+good.title+`","isCustom":true`)
}

func TestWriteJSONStringEscapesControlsAndPreservesUnicode(t *testing.T) {
	var b strings.Builder
	writeJSONString(&b, "\"\\\b\f\n\r\t\x00\x01\x1b\x1f bad\xff\xfe 🧩")
	uassert.Equal(t, `"\"\\\b\f\n\r\t\u0000\u0001\u001b\u001f bad� 🧩"`, b.String())
}

func TestGetTodayJSONListsDailyRoundsAndNewestQuickRounds(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	creator := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, creator)
	const unseeded = `{"nowUnix":1795651200,"dayId":20783,"domain":"colorado/v1",` +
		`"today":{"seeded":false,"classic":null,"twisted":null},` +
		`"yesterday":{"dayId":20782,"classic":null,"twisted":null},"recentQuickRounds":[],"availableRules":[` +
		`{"ruleKey":"wca_obtm","title":"Classic Fewest Moves","isCustom":false},` +
		`{"ruleKey":"no_fb","title":"No Front or Back Turns","isCustom":false},` +
		`{"ruleKey":"no_half_turns","title":"Quarter Turns Only","isCustom":false},` +
		`{"ruleKey":"checkpoint_cross_f2l","title":"Step-by-Step: Cross then First Two Layers","isCustom":false},` +
		`{"ruleKey":"pattern_checkerboard","title":"Checkerboard Pattern","isCustom":false}]}`
	uassert.Equal(t, unseeded, GetTodayJSON())
	uassert.Equal(t, 0, challenges.Size())

	EnsureTodayChallenges(cross(cur))
	ensureDayChallenges(20782, 41, benchTestTime-secondsPerDay)
	yesterday := requireChallenge("D:20782:wca")
	addBenchRankedSubmission(yesterday, &submissionRecord{Solver: "slower", OBTM: 33})
	addBenchRankedSubmission(yesterday, &submissionRecord{Solver: "faster", OBTM: 9})
	addBenchRankedSubmission(requireChallenge("D:20783:wca"), &submissionRecord{Solver: "other round", OBTM: 1})

	const customKey = benchTestOwner + ":cached"
	// An absent implementation makes a metadata callback fail immediately.
	customRules.Set(customKey, registeredRule{Key: customKey, Title: `Cached "Title"`, Description: "Cached description"})
	for i := 1; i <= 21; i++ {
		key := "Q:" + strconv.Itoa(i)
		ruleKey := "wca_obtm"
		if i == 21 {
			ruleKey = customKey
		}
		challenges.Set(key, &challengeRecord{RoundKey: key, Kind: "quick", RuleKey: ruleKey, Creator: creator.String()})
		quickRounds.Set(padInt64(int64(i), quickRoundIndexWidth), key)
	}
	got := GetTodayJSON()
	assertBenchContains(t, got, `"today":{"seeded":true,"classic":{"roundKey":"D:20783:wca","kind":"daily_classic"`,
		`"twisted":{"roundKey":"D:20783:twisted","kind":"daily_twisted"`, `"ruleDescription":`, `"scramble":`,
		`"revealCount":2,"bestObtm":9`, `"revealCount":0,"bestObtm":0`,
		`"ruleTitle":"Cached \"Title\"","isCustom":true`,
		`{"ruleKey":"`+customKey+`","title":"Cached \"Title\"","isCustom":true}`)
	last := -1
	for i := 21; i >= 2; i-- {
		pos := strings.Index(got, `"roundKey":"Q:`+strconv.Itoa(i)+`","kind":"quick"`)
		if pos <= last {
			t.Fatalf("quick round %d missing or out of order", i)
		}
		last = pos
	}
	uassert.False(t, strings.Contains(got, `"roundKey":"Q:1"`))
	uassert.Equal(t, 20, strings.Count(got, `"creator":"`+creator.String()+`"`))
	uassert.Equal(t, 19, strings.Count(got, `"isCustom":false,"phase"`))
}

func TestGetChallengeJSONReturnsDetailOrEscapedError(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	caller := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, caller)
	uassert.Equal(t, `{"error":"ERR_ROUND_NOT_FOUND","roundKey":"missing\"\n"}`, GetChallengeJSON("missing\"\n"))
	key := StartQuickRound(cross(cur), "wca_obtm", 40, 60)
	Commit(cross(cur), key, strings.Repeat("a", 64))
	c := requireChallenge(key)
	assertBenchContains(t, GetChallengeJSON(key), `"roundKey":"Q:1","kind":"quick"`,
		`"ruleKey":"wca_obtm","ruleTitle":"Classic Fewest Moves"`, `"ruleDescription":"Solve the cube`,
		`"scramble":"`+c.ScrambleStr+`"`, `"phase":"commit_open","commitDeadline":1795651240,"revealDeadline":1795651300`,
		`"commitCount":1,"revealCount":0`, `"svgDataUri":"`+cube3x3.RenderCubeNetDataURI(c.ScrambleState)+`"`,
		`"unrevealedCount":1`, `"creator":"`+caller.String()+`"`, `"commitWindowSeconds":40`)
	assertBenchContains(t, GetTodayJSON(), `"recentQuickRounds":[{"roundKey":"Q:1","kind":"quick","creator":"`+caller.String()+`"`)
	EnsureTodayChallenges(cross(cur))
	daily := GetChallengeJSON("D:20783:wca")
	assertBenchContains(t, daily, `"kind":"daily_classic"`, `"unrevealedCount":0`)
	uassert.False(t, strings.Contains(daily, `"creator"`))
	uassert.False(t, strings.Contains(daily, `"commitWindowSeconds"`))
}

func TestGetCommitStatusJSONAcrossCommitRevealAndPrune(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:100"
	alice, bob := testutils.TestAddress("alice"), testutils.TestAddress("bob")
	setBenchTestContext(benchTestTime, 42, alice)
	seedBenchRevealChallenge(key)
	alicePrefix := `{"roundKey":"Q:100","caller":"` + alice.String() + `",`
	noCommit := `"committed":false,"commitHash":"","committedAt":0,"updatedCount":0,"revealed":false}`
	uassert.Equal(t, alicePrefix+noCommit, GetCommitStatusJSON(key, alice.String()))
	initialHash := strings.Repeat("a", 64)
	Commit(cross(cur), key, initialHash)
	uassert.Equal(t, alicePrefix+`"committed":true,"commitHash":"`+initialHash+`","committedAt":1795651200,"updatedCount":1,"revealed":false}`,
		GetCommitStatusJSON(key, alice.String()))
	setBenchTestContext(benchTestTime+5, 43, alice)
	hash := commitreveal.ComputeHash(Domain, key, alice.String(), benchTestSolve, benchTestSalt)
	Commit(cross(cur), key, hash)
	uassert.Equal(t, alicePrefix+`"committed":true,"commitHash":"`+hash+`","committedAt":1795651205,"updatedCount":2,"revealed":false}`,
		GetCommitStatusJSON(key, alice.String()))
	uassert.AbortsWithMessage(t, cur, ErrPhaseClosed, func() {
		Reveal(cross(cur), key, benchTestSolve, benchTestSalt, "")
	})
	setBenchTestContext(benchTestTime+6, 44, bob)
	Commit(cross(cur), key, commitreveal.ComputeHash(Domain, key, bob.String(), benchTestSolve, benchTestSalt))
	setBenchTestContext(benchTestTime+30, 48, alice)
	Reveal(cross(cur), key, benchTestSolve, benchTestSalt, "")
	uassert.Equal(t, alicePrefix+`"committed":false,"commitHash":"","committedAt":0,"updatedCount":0,"revealed":true}`,
		GetCommitStatusJSON(key, alice.String()))
	setBenchTestContext(benchTestTime+61, 55, bob)
	uassert.AbortsWithMessage(t, cur, ErrPhaseClosed, func() {
		Reveal(cross(cur), key, benchTestSolve, benchTestSalt, "")
	})
	uassert.Equal(t, 1, PruneExpiredCommits(cross(cur), key, 1))
	uassert.Equal(t, `{"roundKey":"Q:100","caller":"`+bob.String()+`",`+noCommit, GetCommitStatusJSON(key, bob.String()))
	uassert.Equal(t, `{"roundKey":"Q:missing","caller":"g1\"","committed":false,"commitHash":"","committedAt":0,"updatedCount":0,"revealed":false}`,
		GetCommitStatusJSON("Q:missing", `g1"`))
}

func TestGetLeaderboardJSONBlindsEntriesAndClampsLimit(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:100"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	uassert.Equal(t, `{"error":"ERR_ROUND_NOT_FOUND"}`, GetLeaderboardJSON(key, 1))
	seedBenchRevealChallenge(key)
	c := requireChallenge(key)
	addBenchRankedSubmission(c, &submissionRecord{
		Solver: alice.String(), OBTM: 1, QTM: 2, RevealedAt: benchTestTime + 30,
		CanonicalMoves: "F2", Notes: "note\n🧩", ModeTag: "assisted", AgentModel: `Model "X"`,
		Phases: cube3x3.PhaseReport{
			CrossFace: "D", CrossColor: 3, CrossAtMove: 1, F2LAtMove: 2, OLLAtMove: 3, PLLAtMove: 4,
			Segments: []cube3x3.PhaseSegment{{Name: "Cross", StartMove: 1, EndMove: 1, OBTM: 1}},
		},
	})
	uassert.Equal(t, `{"roundKey":"Q:100","phase":"commit_open","totalRevealed":0,"rows":[]}`, GetLeaderboardJSON(key, 25))
	setBenchTestContext(benchTestTime+30, 48, alice)
	for _, limit := range []int{0, -1} {
		uassert.Equal(t, `{"roundKey":"Q:100","phase":"reveal_open","totalRevealed":1,"rows":[]}`, GetLeaderboardJSON(key, limit))
	}
	const phaseJSON = `{"crossFace":"D","crossColor":3,"crossAtMove":1,"f2lAtMove":2,"ollAtMove":3,"pllAtMove":4,"segments":[{"name":"Cross","startMove":1,"endMove":1,"obtm":1}]}`
	uassert.Equal(t, `{"roundKey":"Q:100","phase":"reveal_open","totalRevealed":1,"rows":[{"rank":1,"solver":"`+alice.String()+
		`","obtm":1,"qtm":2,"revealedAt":1795651230,"moves":"F2","notes":"note\n🧩","modeTag":"assisted","agentModel":"Model \"X\"","phases":`+phaseJSON+`}]}`,
		GetLeaderboardJSON(key, 1))
	for i := 2; i <= 101; i++ {
		addBenchRankedSubmission(c, &submissionRecord{Solver: "g1test" + strconv.Itoa(i), OBTM: i, QTM: i, ModeTag: "human"})
	}
	got := GetLeaderboardJSON(key, 1000)
	assertBenchContains(t, got, `"totalRevealed":101`, `"rank":100,"solver":"g1test100"`, `"segments":[]`)
	uassert.Equal(t, 100, strings.Count(got, `"rank":`))
	uassert.Equal(t, 100, strings.Count(got, `"modeTag":`))
	uassert.Equal(t, 100, strings.Count(got, `"agentModel":`))
}

func TestDailyLeaderboardRanksPublishedSolvesByEveryTieBreak(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "D:20782:wca"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime-secondsPerDay, 42, alice)
	EnsureTodayChallenges(cross(cur))
	inverse := cube3x3.FormatMoves(cube3x3.InvertMoves(requireChallenge(key).ScrambleMoves))
	// This 24-turn identity survives inverse normalization. The prefixes below
	// are also identities and vary the scores without changing the result.
	baseSolve := strings.Repeat("R U R' U' ", 6) + inverse
	const baseOBTM = 54 // 24 identity turns plus 30 inverse turns.
	baseQTM := baseOBTM + strings.Count(inverse, "2")
	const tied = "L2 L2 D2 D2 F F' "
	// These cases are in rank order. Alice's address sorts first, but her
	// reveal is later. Bob's address sorts after Charlie's at the same time.
	cases := []struct {
		solver              address
		prefix, mode, model string
		obtmExtra, qtmExtra int
		revealDelay         int64
	}{
		{testutils.TestAddress("charlie"), tied, "assisted", "Gemini 4", 6, 10, 1},
		{testutils.TestAddress("bob"), tied, "ai", "CustomSolver", 6, 10, 1},
		{alice, tied, "human", "", 6, 10, 2},
		{testutils.TestAddress("dana"), "L2 L2 D2 D2 F2 F2 ", "human", "", 6, 12, 0},
		{testutils.TestAddress("erin"), "L L L L D D D D ", "human", "", 8, 8, 0},
	}
	for _, tc := range cases {
		setBenchTestContext(benchTestTime-secondsPerDay, 42, tc.solver)
		hash := commitreveal.ComputeHash(Domain, key, tc.solver.String(), tc.prefix+baseSolve, benchTestSalt)
		Commit(cross(cur), key, hash)
	}
	for _, rank := range []int{4, 5, 2, 1, 3} {
		tc := cases[rank-1]
		setBenchTestContext(benchTestTime+tc.revealDelay, 48, tc.solver)
		if tc.mode == "human" {
			Reveal(cross(cur), key, tc.prefix+baseSolve, benchTestSalt, "")
		} else {
			RevealWithMeta(cross(cur), key, tc.prefix+baseSolve, benchTestSalt, "", tc.mode, tc.model)
		}
	}
	board := GetLeaderboardJSON(key, 5)
	assertBenchContains(t, board, `{"roundKey":"D:20782:wca","phase":"reveal_open","totalRevealed":5,"rows":[`)
	last := -1
	for i, tc := range cases {
		row := `{"rank":` + strconv.Itoa(i+1) + `,"solver":"` + tc.solver.String() +
			`","obtm":` + strconv.Itoa(baseOBTM+tc.obtmExtra) + `,"qtm":` + strconv.Itoa(baseQTM+tc.qtmExtra) +
			`,"revealedAt":` + strconv.FormatInt(benchTestTime+tc.revealDelay, 10) + `,"moves":"` + tc.prefix + baseSolve +
			`","notes":"","modeTag":"` + tc.mode + `","agentModel":"` + tc.model + `"`
		pos := strings.Index(board, row)
		if pos <= last {
			t.Fatalf("rank %d missing or out of order: %s", i+1, board)
		}
		last = pos
	}
	assertBenchContains(t, GetTodayJSON(),
		`"yesterday":{"dayId":20782,"classic":{"roundKey":"D:20782:wca","kind":"daily_classic",`+
			`"ruleKey":"wca_obtm","ruleTitle":"Classic Fewest Moves","phase":"reveal_open",`+
			`"commitDeadline":1795651200,"revealDeadline":1795737600,"commitCount":5,"revealCount":5,"bestObtm":60}`)
}

func TestVerifyDryRunJSONUsesNullablePhases(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:100"
	setBenchTestContext(benchTestTime, 42, testutils.TestAddress("alice"))
	uassert.Equal(t, `{"valid":false,"errorCode":"ERR_ROUND_NOT_FOUND","errorMessage":"Round not found.","canonicalMoves":"","obtm":0,"qtm":0,"solved":false,"phases":null}`,
		VerifyDryRunJSON(key, benchTestSolve))
	seedBenchRevealChallenge(key)
	assertBenchContains(t, VerifyDryRunJSON(key, "nonsense"), `"valid":false,"errorCode":"ERR_INVALID_NOTATION"`,
		`"canonicalMoves":"","obtm":0,"qtm":0,"solved":false,"phases":null`)
	assertBenchContains(t, VerifyDryRunJSON(key, "F'"), `"valid":false,"errorCode":"ERR_TRIVIAL_INVERSE"`, `"solved":true,"phases":null`)
	assertBenchContains(t, VerifyDryRunJSON(key, benchTestSolve), `"valid":true,"errorCode":"","errorMessage":""`,
		`"canonicalMoves":"`+benchTestSolve+`","obtm":25,"qtm":25,"solved":true,"phases":{"crossFace":`,
		`"crossColor":`, `"crossAtMove":`, `"f2lAtMove":`, `"ollAtMove":`, `"pllAtMove":25`, `"segments":[{"name":`)
}

func TestRenderRoundDistinguishesRoundsSharingRule(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	setBenchTestContext(benchTestTime, 42, testutils.TestAddress("alice"))
	EnsureTodayChallenges(cross(cur))
	quick := StartQuickRound(cross(cur), "wca_obtm", 30, 30)
	assertBenchContains(t, Render("round/D:20783:wca"), "\n# Classic Challenge · November 26, 2026\n\n## Classic Fewest Moves\n")
	assertBenchContains(t, Render("round/"+quick), "\n# Quick Round 1\n\n## Classic Fewest Moves\n")
	assertBenchContains(t, Render("round/D:20783:twisted"), "\n# Special Challenge · November 26, 2026\n")
}

func TestRenderDashboardAndRoundRoutes(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	alice := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	setBenchTestContext(benchTestTime, 42, alice)
	assertBenchContains(t, Render(""), "Start Today's Challenges", "$help&func=EnsureTodayChallenges")
	EnsureTodayChallenges(cross(cur))
	ensureDayChallenges(20782, 41, benchTestTime-secondsPerDay)
	const customKey = benchTestOwner + ":cached"
	customRules.Set(customKey, registeredRule{Key: customKey, Title: "Cached | Rule\n# Fake heading", Description: "<script>custom</script>"})
	key := StartQuickRound(cross(cur), "wca_obtm", 30, 30)
	c := requireChallenge(key)
	c.RuleKey = customKey
	Commit(cross(cur), key, strings.Repeat("a", 64))
	addBenchRankedSubmission(c, &submissionRecord{Solver: alice.String(), OBTM: 25, QTM: 26})
	dashboard := Render("")
	assertBenchContains(t, dashboard, "Today's Challenges", "Yesterday's Rounds", "Recent Quick Rounds", "Community Rules",
		":round/D:20783:wca", ":round/D:20783:twisted", ":round/D:20782:wca", ":round/Q:1", `Cached \| Rule \# Fake heading`)
	uassert.False(t, strings.Contains(dashboard, "Start Today's Challenges"))
	roundPath := "round/" + key
	round := Render(roundPath)
	uassert.Equal(t, round, Render("/"+roundPath))
	assertBenchContains(t, round, "\n# Quick Round 1\n\n## Cached | Rule \\# Fake heading\n",
		"Scrambled 3x3 cube net", "data:image/svg+xml;base64,", c.ScrambleStr,
		"Solutions stay hidden", `\<script\>custom\</script\>`)
	uassert.False(t, strings.Contains(round, alice.String()))
	uassert.False(t, strings.Contains(Render("solve/"+key+"/"+alice.String()), "moves"))
	setBenchTestContext(benchTestTime+30, 48, alice)
	solvePath := "solve/Q:1/" + alice.String()
	assertBenchContains(t, Render(roundPath), "Leaderboard", ":"+solvePath)
	solve := Render(solvePath)
	assertBenchContains(t, solve, "25 moves · 26 quarter turns")
	uassert.Equal(t, solve, Render("/"+solvePath))
	uassert.False(t, strings.Contains(Render("round/"+key), "Clean Up Expired Entries"))
	setBenchTestContext(benchTestTime+60, 54, alice)
	assertBenchContains(t, Render("round/"+key), "Clean Up Expired Entries", "$help&func=PruneExpiredCommits&roundKey=Q:1&maxDelete=50")
	PruneExpiredCommits(cross(cur), key, 0)
	uassert.False(t, strings.Contains(Render("round/"+key), "Clean Up Expired Entries"))
	assertBenchContains(t, Render("round/missing"), "Round not found")
	assertBenchContains(t, Render("solve/"+key+"/missing"), "Solution not found")
}

func TestRenderSolveRanksByRoundLeaderboardKeys(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:1"
	setBenchTestContext(benchTestTime+30, 48, testutils.TestAddress("alice"))
	seedBenchRevealChallenge(key)
	c := requireChallenge(key)
	wantOrder := []*submissionRecord{
		{Solver: "g1charlie", OBTM: 23, QTM: 24, RevealedAt: benchTestTime + 35},
		{Solver: "g1alice", OBTM: 23, QTM: 25, RevealedAt: benchTestTime + 30},
		{Solver: "g1bob", OBTM: 23, QTM: 25, RevealedAt: benchTestTime + 30},
		{Solver: "g1aaron", OBTM: 23, QTM: 25, RevealedAt: benchTestTime + 31},
	}
	for i := len(wantOrder) - 1; i >= 0; i-- {
		sub := wantOrder[i]
		addBenchRankedSubmission(c, sub)
		submissions.Remove(key + "|" + sub.Solver)
	}
	for _, otherKey := range []string{"D:20783:wca", "Q:10", "Q:2"} {
		addBenchRankedSubmission(&challengeRecord{RoundKey: otherKey}, &submissionRecord{Solver: "g1alice", OBTM: 1})
	}
	for i, sub := range wantOrder {
		// Keep only the requested solve payload for this round. Its rank must come from the index.
		entry := key + "|" + sub.Solver
		submissions.Set(entry, sub)
		assertBenchContains(t, Render("solve/"+key+"/"+sub.Solver), "Rank "+strconv.Itoa(i+1)+" · 23 moves")
		submissions.Remove(entry)
	}
}

func TestRenderSolveSafelyShowsPublishedMetadata(cur realm, t *testing.T) {
	defer isolateBenchTestState()()
	const key = "Q:100"
	alice := testutils.TestAddress("alice")
	setBenchTestContext(benchTestTime, 42, alice)
	seedBenchRevealChallenge(key)
	c := requireChallenge(key)
	addBenchRankedSubmission(c, &submissionRecord{Solver: "another-solver", OBTM: 24})
	hash := commitreveal.ComputeHash(Domain, key, alice.String(), benchTestSolve, benchTestSalt)
	Commit(cross(cur), key, hash)
	setBenchTestContext(benchTestTime+30, 48, alice)
	const notes = "<script>alert(1)</script>\n[evil](javascript:alert(2))\n# Fake heading\n\"quoted\" \\ 🧩"
	const model = "<script>model</script> [evil](javascript:alert(3)) # Heading"
	RevealWithMeta(cross(cur), key, benchTestSolve, benchTestSalt, notes, "assisted", model)
	assertBenchContains(t, GetLeaderboardJSON(key, 2),
		`"notes":"<script>alert(1)</script>\n[evil](javascript:alert(2))\n# Fake heading\n\"quoted\" \\ 🧩","modeTag":"assisted"`)
	path := "solve/" + key + "/" + alice.String()
	got := Render(path)
	assertBenchContains(t, got, "Rank 2", "moves", "quarter turns", "Solve method (self-declared)", "Human + AI", benchTestSolve, "Cross", "F2L", "OLL", "PLL",
		`\<script\>alert\(1\)\</script\>`, `\<script\>model\</script\>`, `\[evil\]\(javascript:alert\(2\)\)`,
		`\[evil\]\(javascript:alert\(3\)\) \# Heading`, `\# Fake heading "quoted"`)
	for _, raw := range []string{"<script>", "[evil](javascript:", "\n# Fake heading", "ERR_", "\u2014"} {
		uassert.False(t, strings.Contains(got, raw))
	}
	sub := submissions.Get(key + "|" + alice.String()).(*submissionRecord)
	sub.ModeTag, sub.AgentModel = "ai", ""
	assertBenchContains(t, Render(path), "AI Only")
	sub.ModeTag = "human"
	assertBenchContains(t, Render(path), "Human")
	uassert.False(t, strings.Contains(Render(path), "Human + AI"))
}

func addBenchRankedSubmission(c *challengeRecord, sub *submissionRecord) {
	submissions.Set(c.RoundKey+"|"+sub.Solver, sub)
	leaderboards, _ = leaderboards.Set(leaderboardKey(c.RoundKey, sub), sub.Solver)
	c.RevealCount++
}

func assertBenchContains(t *testing.T, got string, fragments ...string) {
	t.Helper()
	for _, fragment := range fragments {
		if !strings.Contains(got, fragment) {
			t.Errorf("missing fragment %q in %q", fragment, got)
		}
	}
}
