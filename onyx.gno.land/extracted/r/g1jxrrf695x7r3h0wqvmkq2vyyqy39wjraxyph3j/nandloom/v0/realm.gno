package nandloom

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	nl "gno.land/p/g1jxrrf695x7r3h0wqvmkq2vyyqy39wjraxyph3j/nandloom/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	realmPathPrefix = "/r/g1jxrrf695x7r3h0wqvmkq2vyyqy39wjraxyph3j/nandloom/v0"
	EventChipVerify = "ChipVerified"
)

var (
	challenges       *avl.Tree // challengeID -> *ChallengeState
	challengeOrder   []string
	chips            *avl.Tree // slug -> *ChipEntry
	builders         *avl.Tree // addr.String() -> *BuilderProfile
	totalSubmissions int
	totalReuses      int
)

func init(cur realm) {
	challenges = avl.NewTree()
	chips = avl.NewTree()
	builders = avl.NewTree()

	specs := nl.DefaultChallenges()
	challengeOrder = make([]string, 0, len(specs))
	for i := 0; i < len(specs); i++ {
		sp := specs[i]
		challengeOrder = append(challengeOrder, sp.ID)
		challenges.Set(sp.ID, &ChallengeState{
			Spec: sp,
		})
	}

	seedAuthor := cur.Previous().Address()
	if !seedAuthor.IsValid() {
		seedAuthor = cur.Address()
	}

	refs := nl.DefaultReferenceChips()
	for i := 0; i < len(refs); i++ {
		r := refs[i]
		mustInsertChip(seedAuthor, r.ChallengeID, r.Slug, r.Title, r.Notes, r.Netlist)
	}
}

func resolveChip(slug string) (*nl.Circuit, bool) {
	v := chips.Get(slug)
	if v == nil {
		return nil, false
	}
	entry := v.(*ChipEntry)
	return entry.AST, true
}

func getOrCreateBuilder(addr address) *BuilderProfile {
	key := addr.String()
	if v := builders.Get(key); v != nil {
		return v.(*BuilderProfile)
	}
	bp := &BuilderProfile{
		Address:          addr,
		SolvedChallenges: make(map[string]bool),
	}
	builders.Set(key, bp)
	return bp
}

func mustInsertChip(author address, challengeID, slug, title, notes, netlist string) (*ChipEntry, bool) {
	chVal := challenges.Get(challengeID)
	if chVal == nil {
		panic("unknown challenge: " + challengeID)
	}
	ch := chVal.(*ChallengeState)

	if !nl.IsValidSlug(slug) {
		panic("invalid chip slug: must match [a-z][a-z0-9_-]{0,31}")
	}
	if chips.Has(slug) {
		panic("chip slug already exists (verified chips are immutable): " + slug)
	}
	title = strings.TrimSpace(title)
	notes = strings.TrimSpace(notes)
	if title == "" {
		panic("chip title cannot be empty")
	}
	if len(title) > MaxTitleLen {
		panic(ufmt.Sprintf("chip title exceeds %d chars", MaxTitleLen))
	}
	if len(notes) > MaxNotesLen {
		panic(ufmt.Sprintf("chip notes exceed %d chars", MaxNotesLen))
	}

	ast, err := nl.Parse(netlist)
	if err != nil {
		panic("netlist parse error: " + err.Error())
	}
	cc, err := nl.Compile(ast, resolveChip)
	if err != nil {
		panic("netlist compile error: " + err.Error())
	}
	vr := nl.Verify(cc, ch.Spec)
	if !vr.Passed {
		panic("verification failed: " + vr.ErrorMessage)
	}

	entry := &ChipEntry{
		Slug:          slug,
		ChallengeID:   challengeID,
		Title:         title,
		Notes:         notes,
		Author:        author,
		BlockHeight:   runtime.ChainHeight(),
		Netlist:       ast.Raw,
		AST:           ast,
		Compiled:      cc,
		NANDCount:     cc.NANDCount,
		Depth:         cc.MaxDepth,
		ModuleCount:   cc.ModuleCount,
		ImportedChips: cc.ImportedChips,
	}
	chips.Set(slug, entry)
	ch.SubmissionSlugs = append(ch.SubmissionSlugs, slug)
	totalSubmissions++

	// Update builder stats.
	bp := getOrCreateBuilder(author)
	bp.ChipsSubmitted++
	bp.SolvedChallenges[challengeID] = true

	// Credit composable sub-chip reuse on every direct dependency.
	for i := 0; i < len(cc.ImportedChips); i++ {
		depSlug := cc.ImportedChips[i]
		if dv := chips.Get(depSlug); dv != nil {
			dep := dv.(*ChipEntry)
			dep.ReuseCount++
			if len(dep.Importers) < MaxImportersCap {
				dep.Importers = append(dep.Importers, slug)
			}
			totalReuses++
			depBuilder := getOrCreateBuilder(dep.Author)
			depBuilder.TotalReuses++
		}
	}

	// Deterministic record rule: fewer flattened NANDs wins; ties broken by shallower depth,
	// then earlier submission (strictly < required to unseat an existing record).
	newRecord := false
	if ch.BestSlug == "" ||
		entry.NANDCount < ch.BestNANDs ||
		(entry.NANDCount == ch.BestNANDs && entry.Depth < ch.BestDepth) {
		if ch.BestSlug != "" {
			if prevB := builders.Get(ch.BestAuthor.String()); prevB != nil {
				pb := prevB.(*BuilderProfile)
				if pb.RecordsHeld > 0 {
					pb.RecordsHeld--
				}
			}
		}
		ch.BestSlug = slug
		ch.BestNANDs = entry.NANDCount
		ch.BestDepth = entry.Depth
		ch.BestAuthor = author
		bp.RecordsHeld++
		newRecord = true
	}

	return entry, newRecord
}

// SubmitChip parses, compiles (resolving verified chip:<slug> imports), verifies
// against every challenge test vector, and permanently registers the chip on-chain.
//
// Crossing safety: enforces cur.IsCurrent() and derives caller strictly from
// cur.Previous().Address().
func SubmitChip(cur realm, challengeID, slug, title, notes, netlist string) string {
	if !cur.IsCurrent() {
		panic("unauthorized crossing context")
	}
	caller := cur.Previous().Address()
	if !caller.IsValid() {
		panic("invalid caller address")
	}

	entry, newRecord := mustInsertChip(caller, challengeID, slug, title, notes, netlist)

	recStr := "false"
	if newRecord {
		recStr = "true"
	}
	chain.Emit(
		EventChipVerify,
		"slug", entry.Slug,
		"challenge", entry.ChallengeID,
		"author", caller.String(),
		"nands", strconv.Itoa(entry.NANDCount),
		"depth", strconv.Itoa(entry.Depth),
		"new_record", recStr,
	)

	if newRecord {
		return ufmt.Sprintf("VERIFIED NEW RECORD: %s (%d NANDs, depth %d) for %s",
			entry.Slug, entry.NANDCount, entry.Depth, entry.ChallengeID)
	}
	return ufmt.Sprintf("VERIFIED: %s (%d NANDs, depth %d) for %s",
		entry.Slug, entry.NANDCount, entry.Depth, entry.ChallengeID)
}

// EvalChip is a cross-realm composable API allowing any other Gno realm or
// off-chain vm/qeval client to run a verified on-chain chip on a bitstring.
func EvalChip(slug, bits string) string {
	v := chips.Get(slug)
	if v == nil {
		panic("unknown chip: " + slug)
	}
	entry := v.(*ChipEntry)
	tr, err := nl.EvalBits(entry.Compiled, bits)
	if err != nil {
		panic(err.Error())
	}
	return tr.OutputBits
}

// VerifyExternal runs a pure read-only parse, compile, and exhaustive vector check
// against the live verified chip registry without mutating chain state.
func VerifyExternal(challengeID, netlist string) string {
	chVal := challenges.Get(challengeID)
	if chVal == nil {
		return "FAIL|unknown challenge: " + challengeID
	}
	ch := chVal.(*ChallengeState)
	ast, err := nl.Parse(netlist)
	if err != nil {
		return "FAIL|parse: " + err.Error()
	}
	cc, err := nl.Compile(ast, resolveChip)
	if err != nil {
		return "FAIL|compile: " + err.Error()
	}
	vr := nl.Verify(cc, ch.Spec)
	if !vr.Passed {
		return "FAIL|" + vr.ErrorMessage
	}
	beats := "false"
	if ch.BestSlug == "" || cc.NANDCount < ch.BestNANDs || (cc.NANDCount == ch.BestNANDs && cc.MaxDepth < ch.BestDepth) {
		beats = "true"
	}
	return ufmt.Sprintf("PASS|nands=%d|depth=%d|vectors=%d/%d|beats_record=%s|imports=%s",
		cc.NANDCount, cc.MaxDepth, vr.PassedVectors, vr.TotalVectors, beats, strings.Join(cc.ImportedChips, ","))
}

// GetChipInfo returns typed metadata for a verified chip (cross-realm API).
func GetChipInfo(slug string) (challengeID, title, author string, nands, depth, reuses int, ok bool) {
	v := chips.Get(slug)
	if v == nil {
		return "", "", "", 0, 0, 0, false
	}
	e := v.(*ChipEntry)
	return e.ChallengeID, e.Title, e.Author.String(), e.NANDCount, e.Depth, e.ReuseCount, true
}

// SnapshotJSON returns a deterministic JSON snapshot of live on-chain challenges,
// verified chips, and builder stats for zero-backend RPC web clients (vm/qeval).
func SnapshotJSON() string {
	var b strings.Builder
	b.WriteString("{")
	b.WriteString(ufmt.Sprintf(`"chain_height":%d,"total_chips":%d,"total_reuses":%d,"challenges":[`,
		runtime.ChainHeight(), chips.Size(), totalReuses))

	for i := 0; i < len(challengeOrder); i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		ch := challenges.Get(challengeOrder[i]).(*ChallengeState)
		b.WriteString("{")
		b.WriteString(`"id":` + jsonStr(ch.Spec.ID))
		b.WriteString(`,"title":` + jsonStr(ch.Spec.Title))
		b.WriteString(`,"summary":` + jsonStr(ch.Spec.Summary))
		b.WriteString(`,"difficulty":` + jsonStr(ch.Spec.Difficulty))
		b.WriteString(`,"inputs":` + jsonStrSlice(ch.Spec.Inputs))
		b.WriteString(`,"outputs":` + jsonStrSlice(ch.Spec.Outputs))
		b.WriteString(ufmt.Sprintf(`,"par_nands":%d,"par_depth":%d,"vectors":%d`,
			ch.Spec.ParNANDs, ch.Spec.ParDepth, len(ch.Spec.Vectors)))
		b.WriteString(`,"best_slug":` + jsonStr(ch.BestSlug))
		b.WriteString(ufmt.Sprintf(`,"best_nands":%d,"best_depth":%d`, ch.BestNANDs, ch.BestDepth))
		b.WriteString(`,"best_author":` + jsonStr(ch.BestAuthor.String()))
		b.WriteString(`,"starter_netlist":` + jsonStr(ch.Spec.StarterNetlist))
		b.WriteString(ufmt.Sprintf(`,"submission_count":%d`, len(ch.SubmissionSlugs)))
		b.WriteString("}")
	}

	b.WriteString(`],"chips":[`)
	firstChip := true
	chips.Iterate("", "", func(_ string, v any) bool {
		e := v.(*ChipEntry)
		if !firstChip {
			b.WriteByte(',')
		}
		firstChip = false
		b.WriteString("{")
		b.WriteString(`"slug":` + jsonStr(e.Slug))
		b.WriteString(`,"challenge_id":` + jsonStr(e.ChallengeID))
		b.WriteString(`,"title":` + jsonStr(e.Title))
		b.WriteString(`,"notes":` + jsonStr(e.Notes))
		b.WriteString(`,"author":` + jsonStr(e.Author.String()))
		b.WriteString(ufmt.Sprintf(`,"block_height":%d,"nands":%d,"depth":%d,"modules":%d,"reuses":%d`,
			e.BlockHeight, e.NANDCount, e.Depth, e.ModuleCount, e.ReuseCount))
		b.WriteString(`,"imports":` + jsonStrSlice(e.ImportedChips))
		b.WriteString(`,"importers":` + jsonStrSlice(e.Importers))
		b.WriteString(`,"netlist":` + jsonStr(e.Netlist))
		b.WriteString("}")
		return false
	})

	b.WriteString(`],"builders":[`)
	sortedB := sortedBuilders()
	for i := 0; i < len(sortedB); i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		bp := sortedB[i]
		b.WriteString("{")
		b.WriteString(`"address":` + jsonStr(bp.Address.String()))
		b.WriteString(ufmt.Sprintf(`,"chips":%d,"records":%d,"reuses":%d,"solved":%d`,
			bp.ChipsSubmitted, bp.RecordsHeld, bp.TotalReuses, len(bp.SolvedChallenges)))
		b.WriteString("}")
	}
	b.WriteString("]}")
	return b.String()
}

func builderBetter(a, b *BuilderProfile) bool {
	if a.RecordsHeld != b.RecordsHeld {
		return a.RecordsHeld > b.RecordsHeld
	}
	if a.TotalReuses != b.TotalReuses {
		return a.TotalReuses > b.TotalReuses
	}
	if len(a.SolvedChallenges) != len(b.SolvedChallenges) {
		return len(a.SolvedChallenges) > len(b.SolvedChallenges)
	}
	return a.Address.String() < b.Address.String()
}

func sortedBuilders() []*BuilderProfile {
	out := make([]*BuilderProfile, 0, builders.Size())
	builders.Iterate("", "", func(_ string, v any) bool {
		out = append(out, v.(*BuilderProfile))
		return false
	})
	for i := 1; i < len(out); i++ {
		cur := out[i]
		j := i - 1
		for j >= 0 && builderBetter(cur, out[j]) {
			out[j+1] = out[j]
			j--
		}
		out[j+1] = cur
	}
	return out
}

func chipBetter(a, b *ChipEntry) bool {
	if a.NANDCount != b.NANDCount {
		return a.NANDCount < b.NANDCount
	}
	if a.Depth != b.Depth {
		return a.Depth < b.Depth
	}
	if a.BlockHeight != b.BlockHeight {
		return a.BlockHeight < b.BlockHeight
	}
	return a.Slug < b.Slug
}

func sortedChallengeChips(slugs []string) []*ChipEntry {
	out := make([]*ChipEntry, 0, len(slugs))
	for i := 0; i < len(slugs); i++ {
		if v := chips.Get(slugs[i]); v != nil {
			out = append(out, v.(*ChipEntry))
		}
	}
	for i := 1; i < len(out); i++ {
		cur := out[i]
		j := i - 1
		for j >= 0 && chipBetter(cur, out[j]) {
			out[j+1] = out[j]
			j--
		}
		out[j+1] = cur
	}
	return out
}

func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(ufmt.Sprintf(`\u%04x`, int(c)))
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func jsonStrSlice(ss []string) string {
	var b strings.Builder
	b.WriteByte('[')
	for i := 0; i < len(ss); i++ {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(jsonStr(ss[i]))
	}
	b.WriteByte(']')
	return b.String()
}
