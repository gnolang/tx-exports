package bench

import (
	"strings"
	"time"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/commitreveal"
	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

func writeJSONString(b *strings.Builder, s string) {
	const digits = "0123456789abcdef"
	s = strings.ToValidUTF8(s, "\uFFFD")
	b.WriteByte('"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		var escape string
		switch c {
		case '"':
			escape = `\"`
		case '\\':
			escape = `\\`
		case '\b':
			escape = `\b`
		case '\f':
			escape = `\f`
		case '\n':
			escape = `\n`
		case '\r':
			escape = `\r`
		case '\t':
			escape = `\t`
		default:
			if c >= 0x20 {
				continue
			}
		}
		b.WriteString(s[start:i])
		if escape == "" {
			b.WriteString(`\u00`)
			b.WriteByte(digits[c>>4])
			b.WriteByte(digits[c&0xf])
		} else {
			b.WriteString(escape)
		}
		start = i + 1
	}
	b.WriteString(s[start:])
	b.WriteByte('"')
}

func writeJSONText(b *strings.Builder, prefix, value string) {
	b.WriteString(prefix)
	writeJSONString(b, value)
}

func dailyRounds(dayID int64) (classic, twisted *challengeRecord) {
	prefix := dailyRoundPrefix(dayID)
	classic, _ = challenges.Get(prefix + "wca").(*challengeRecord)
	twisted, _ = challenges.Get(prefix + "twisted").(*challengeRecord)
	return classic, twisted
}

func roundRuleMetadata(ruleKey string) (title, description string, isCustom bool) {
	if rule, ok := cube3x3.BuiltinRule(ruleKey); ok {
		return rule.Title(), rule.Description(), false
	}
	entry, _ := customRules.Get(ruleKey).(registeredRule)
	return entry.Title, entry.Description, true
}

func forEachRecentQuickRound(visit func(*challengeRecord)) {
	quickRounds.ReverseIterateByOffset(0, RecentQuickRoundsLimit, func(_ string, value any) bool {
		if c, ok := challenges.Get(value.(string)).(*challengeRecord); ok {
			visit(c)
		}
		return false
	})
}

func forEachRankedSubmission(roundKey string, visit func(rank int, sub *submissionRecord) bool) {
	prefix := roundKey + "|"
	rank := 0
	leaderboards.Iterate(prefix, prefixRangeEnd(prefix), func(row *avl.Node) bool {
		sub, ok := submissions.Get(prefix + row.Value().(string)).(*submissionRecord)
		if !ok {
			return false
		}
		rank++
		return visit(rank, sub)
	})
}

func bestObtm(roundKey string) int {
	best := 0
	forEachRankedSubmission(roundKey, func(_ int, sub *submissionRecord) bool {
		best = sub.OBTM
		return true
	})
	return best
}

type roundJSONView uint8

const (
	todayRoundJSON roundJSONView = iota
	yesterdayRoundJSON
	quickRoundJSON
	challengeDetailJSON
)

func writeRoundJSON(b *strings.Builder, c *challengeRecord, nowUnix int64, view roundJSONView) {
	if c == nil {
		b.WriteString("null")
		return
	}
	title, description, isCustom := roundRuleMetadata(c.RuleKey)
	writeJSONText(b, `{"roundKey":`, c.RoundKey)
	writeJSONText(b, `,"kind":`, c.Kind)
	if c.Kind == "quick" {
		writeJSONText(b, `,"creator":`, c.Creator)
	}
	writeJSONText(b, `,"ruleKey":`, c.RuleKey)
	writeJSONText(b, `,"ruleTitle":`, title)
	switch view {
	case todayRoundJSON, challengeDetailJSON:
		writeJSONText(b, `,"ruleDescription":`, description)
		writeJSONText(b, `,"scramble":`, c.ScrambleStr)
	case quickRoundJSON:
		ufmt.Fprintf(b, `,"isCustom":%t`, isCustom)
	}
	writeJSONText(b, `,"phase":`, computePhase(c, nowUnix))
	ufmt.Fprintf(b, `,"commitDeadline":%d,"revealDeadline":%d,"commitCount":%d,"revealCount":%d`,
		c.CommitDeadline, c.RevealDeadline, c.CommitCount, c.RevealCount)
	switch view {
	case yesterdayRoundJSON:
		ufmt.Fprintf(b, `,"bestObtm":%d`, bestObtm(c.RoundKey))
	case challengeDetailJSON:
		writeJSONText(b, `,"svgDataUri":`, cube3x3.RenderCubeNetDataURI(c.ScrambleState))
		ufmt.Fprintf(b, `,"unrevealedCount":%d`, c.UnrevealedCount)
		if c.Kind == "quick" {
			ufmt.Fprintf(b, `,"commitWindowSeconds":%d`, c.CommitWindowSeconds)
		}
	}
	b.WriteByte('}')
}

func writeRuleOptionJSON(b *strings.Builder, key, title string, isCustom bool) {
	writeJSONText(b, `{"ruleKey":`, key)
	writeJSONText(b, `,"title":`, title)
	ufmt.Fprintf(b, `,"isCustom":%t}`, isCustom)
}

// GetTodayJSON returns the daily challenges, recent quick rounds, and rule options.
func GetTodayJSON() string {
	nowUnix := time.Now().Unix()
	dayID := nowUnix / secondsPerDay
	classic, twisted := dailyRounds(dayID)
	seeded := classic != nil && twisted != nil
	if !seeded {
		classic, twisted = nil, nil
	}
	var b strings.Builder
	ufmt.Fprintf(&b, `{"nowUnix":%d,"dayId":%d`, nowUnix, dayID)
	writeJSONText(&b, `,"domain":`, Domain)
	ufmt.Fprintf(&b, `,"today":{"seeded":%t,"classic":`, seeded)
	writeRoundJSON(&b, classic, nowUnix, todayRoundJSON)
	b.WriteString(`,"twisted":`)
	writeRoundJSON(&b, twisted, nowUnix, todayRoundJSON)

	classic, twisted = dailyRounds(dayID - 1)
	ufmt.Fprintf(&b, `},"yesterday":{"dayId":%d,"classic":`, dayID-1)
	writeRoundJSON(&b, classic, nowUnix, yesterdayRoundJSON)
	b.WriteString(`,"twisted":`)
	writeRoundJSON(&b, twisted, nowUnix, yesterdayRoundJSON)

	b.WriteString(`},"recentQuickRounds":[`)
	first := true
	forEachRecentQuickRound(func(c *challengeRecord) {
		if !first {
			b.WriteByte(',')
		}
		first = false
		writeRoundJSON(&b, c, nowUnix, quickRoundJSON)
	})
	b.WriteString(`],"availableRules":[`)
	for i, key := range []string{"wca_obtm", "no_fb", "no_half_turns", "checkpoint_cross_f2l", "pattern_checkerboard"} {
		if i > 0 {
			b.WriteByte(',')
		}
		title, _, _ := roundRuleMetadata(key)
		writeRuleOptionJSON(&b, key, title, false)
	}
	customRules.Iterate("", "", func(key string, value any) bool {
		b.WriteByte(',')
		writeRuleOptionJSON(&b, key, value.(registeredRule).Title, true)
		return false
	})
	b.WriteString(`]}`)
	return b.String()
}

// GetChallengeJSON returns the round details or a round-not-found response.
func GetChallengeJSON(roundKey string) string {
	var b strings.Builder
	if c, ok := challenges.Get(roundKey).(*challengeRecord); ok {
		writeRoundJSON(&b, c, time.Now().Unix(), challengeDetailJSON)
	} else {
		writeJSONText(&b, `{"error":`, ErrRoundNotFound)
		writeJSONText(&b, `,"roundKey":`, roundKey)
		b.WriteByte('}')
	}
	return b.String()
}

// GetCommitStatusJSON reports the caller's pending commitment and published solve.
func GetCommitStatusJSON(roundKey string, addr string) string {
	key := roundKey + "|" + addr
	rec, committed := commits.Get(key).(commitreveal.Record)
	revealed := submissions.Has(key)

	var b strings.Builder
	writeJSONText(&b, `{"roundKey":`, roundKey)
	writeJSONText(&b, `,"caller":`, addr)
	ufmt.Fprintf(&b, `,"committed":%t`, committed)
	writeJSONText(&b, `,"commitHash":`, rec.CommitHash)
	ufmt.Fprintf(&b, `,"committedAt":%d,"updatedCount":%d,"revealed":%t}`, rec.CommittedAt, rec.UpdatedCount, revealed)
	return b.String()
}

// GetLeaderboardJSON returns up to limit published solves in score order.
func GetLeaderboardJSON(roundKey string, limit int) string {
	c, ok := challenges.Get(roundKey).(*challengeRecord)
	if !ok {
		return `{"error":"` + ErrRoundNotFound + `"}`
	}
	phase := computePhase(c, time.Now().Unix())
	total := c.RevealCount
	if phase == "commit_open" {
		total, limit = 0, 0
	} else if limit > MaxLeaderboardLimit {
		limit = MaxLeaderboardLimit
	}

	var b strings.Builder
	writeJSONText(&b, `{"roundKey":`, roundKey)
	writeJSONText(&b, `,"phase":`, phase)
	ufmt.Fprintf(&b, `,"totalRevealed":%d,"rows":[`, total)
	if limit > 0 {
		forEachRankedSubmission(roundKey, func(rank int, sub *submissionRecord) bool {
			if rank > 1 {
				b.WriteByte(',')
			}
			writeLeaderboardRowJSON(&b, rank, sub)
			return rank == limit
		})
	}
	b.WriteString(`]}`)
	return b.String()
}

func writeLeaderboardRowJSON(b *strings.Builder, rank int, sub *submissionRecord) {
	ufmt.Fprintf(b, `{"rank":%d`, rank)
	writeJSONText(b, `,"solver":`, sub.Solver)
	ufmt.Fprintf(b, `,"obtm":%d,"qtm":%d,"revealedAt":%d`, sub.OBTM, sub.QTM, sub.RevealedAt)
	writeJSONText(b, `,"moves":`, sub.CanonicalMoves)
	writeJSONText(b, `,"notes":`, sub.Notes)
	writeJSONText(b, `,"modeTag":`, sub.ModeTag)
	writeJSONText(b, `,"agentModel":`, sub.AgentModel)
	b.WriteString(`,"phases":`)
	writePhaseReportJSON(b, &sub.Phases)
	b.WriteByte('}')
}

func writePhaseReportJSON(b *strings.Builder, phases *cube3x3.PhaseReport) {
	if phases == nil {
		b.WriteString("null")
		return
	}
	writeJSONText(b, `{"crossFace":`, phases.CrossFace)
	ufmt.Fprintf(b, `,"crossColor":%d,"crossAtMove":%d,"f2lAtMove":%d,"ollAtMove":%d,"pllAtMove":%d,"segments":[`,
		int(phases.CrossColor), phases.CrossAtMove, phases.F2LAtMove, phases.OLLAtMove, phases.PLLAtMove)
	for i, segment := range phases.Segments {
		if i > 0 {
			b.WriteByte(',')
		}
		writeJSONText(b, `{"name":`, segment.Name)
		ufmt.Fprintf(b, `,"startMove":%d,"endMove":%d,"obtm":%d}`, segment.StartMove, segment.EndMove, segment.OBTM)
	}
	b.WriteString(`]}`)
}

// VerifyDryRunJSON checks a proposed solution without creating a submission.
func VerifyDryRunJSON(roundKey string, moves string) string {
	var result cube3x3.VerifyResult
	if c, ok := challenges.Get(roundKey).(*challengeRecord); ok {
		rule, _ := resolveRule(c.RuleKey)
		result = cube3x3.VerifySolution(c.ScrambleMoves, moves, rule)
	} else {
		result.ErrorCode = ErrRoundNotFound
		result.ErrorMessage = "Round not found."
	}

	var b strings.Builder
	ufmt.Fprintf(&b, `{"valid":%t`, result.Valid)
	writeJSONText(&b, `,"errorCode":`, result.ErrorCode)
	writeJSONText(&b, `,"errorMessage":`, result.ErrorMessage)
	writeJSONText(&b, `,"canonicalMoves":`, result.CanonicalMoves)
	ufmt.Fprintf(&b, `,"obtm":%d,"qtm":%d,"solved":%t,"phases":`, result.OBTM, result.QTM, result.Solved)
	writePhaseReportJSON(&b, result.Phases)
	b.WriteByte('}')
	return b.String()
}
