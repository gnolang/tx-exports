// Rule implementations for auditrules.
//
// Each rule has one internal check that works on a parsed source (so
// Audit parses once) and one exported Check function that parses its
// input first (so a caller can run a single rule on its own).
//
// Overlap policy, so one root cause does not produce a stack of findings
// for the same line: IssueCoin is covered by RC-02, not RC-01. Mint and
// withdraw style functions are covered by RC-01, RC-02, and RC-03, not
// RC-08. Append growth is covered by RC-04, not RC-08. A guard that lives
// in a wrapper function does not count: the guard must appear in the same
// function body, because this scanner does not follow calls. That choice
// can produce a false positive when the guard is in the caller; the
// description of each rule says so where it matters. The same applies to
// a mutation inside a closure passed to another function, such as a DAO
// proposal executor: the closure body is scanned as part of the enclosing
// function, because the scanner cannot prove the callee only runs it
// after a vote, and trusting the callee name would hide a real finding in
// a realm that invokes the closure immediately.

package auditrules

import "strings"

// guardTokens are text shapes that count as a caller check inside a
// function body. They cover the standard Gno caller primitives
// (IsUser, IsRealm, OriginCaller, PreviousRealm, AssertOriginCall) and
// the common owner and admin guard idioms. Note: IsUser on its own is a
// weaker guard than IsUserCall for payment paths, because IsUser also
// accepts MsgRun ephemeral realms. This scanner counts it, per the rule
// definition; a stricter payment-path rule is future work.
// Any assert* helper call counts as a guard: by Gno convention an assert
// helper panics when its check fails, so a function that calls one is
// guarded on the condition it asserts. Admin and owner comparisons in
// either order count, so `caller != Admin` and `Admin != caller` are
// both recognized.
var guardTokens = []string{
	"IsUserCall", "IsUserRun", "IsUser(", "IsRealm(", "OriginCaller",
	"AssertOriginCall", "PreviousRealm", "AssertCaller", "IsCurrent(",
	"OnlyOwner", "AssertOwner", "RequireOwner", "MustBeOwner",
	"CheckOwner", "AssertAuthorized", "RequireAdmin", "AssertAdmin",
	"IsAdmin(", "IsOwner(", "Authorized",
	"assert", "Assert",
	"owner ==", "owner !=", "admin ==", "admin !=",
	"Owner ==", "Owner !=", "Admin ==", "Admin !=",
	"caller ==", "caller !=",
}

// timelockTokens suppress the admin backdoor rule: a drain that can only
// run after a delay, or only with several approvals, is not a silent
// single-key backdoor.
var timelockTokens = []string{
	"Timelock", "timelock", "TimeLock", "UnlockTime", "unlockTime",
	"ExecuteAfter", "executeAfter", "MinDelay", "minDelay",
	"TooEarly", "tooEarly", "NotYet", "Scheduled", "scheduled",
}

// multisigTokens suppress the admin backdoor rule for the same reason.
var multisigTokens = []string{
	"MultiSig", "multisig", "Threshold", "threshold",
	"Approvals", "approvals", "Confirmations", "confirmations",
	"Signers", "signers",
}

// CheckNoCallerGuard runs rule RC-01 on src.
func CheckNoCallerGuard(src string) []Finding {
	return checkNoCallerGuard(parseSource(src))
}

// checkNoCallerGuard implements RC-01: an exported function that moves
// funds or changes admin state with no caller guard in its own body.
func checkNoCallerGuard(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleNoCallerGuard)
	actions := []string{
		"SendCoins", "RemoveCoin", "TransferOwnership",
		"SetOwner", "SetAdmin", "ChangeOwner", "ChangeAdmin",
		"Withdraw", "Transfer(",
	}
	var out []Finding
	for _, fn := range ps.funcs {
		if !fn.exported {
			continue
		}
		if strings.Contains(fn.name, "Mint") {
			continue
		}
		if ps.bodyHasAny(fn, guardTokens) {
			continue
		}
		line := ps.firstLineWith(fn, actions)
		if line == 0 {
			continue
		}
		desc := "Function " + fn.name + " moves funds or changes admin state but contains no caller check in its own body. Add a guard such as cur.Previous().IsUserCall(), an OriginCaller comparison against the stored owner, or an AssertOwner call before the sensitive action. A guard in a wrapper function does not count for this check."
		out = append(out, newFinding(rule, line, ps.raw[line-1], desc))
	}
	return out
}

// CheckUnrestrictedMint runs rule RC-02 on src.
func CheckUnrestrictedMint(src string) []Finding {
	return checkUnrestrictedMint(parseSource(src))
}

// checkUnrestrictedMint implements RC-02: a function named Mint that
// issues coins or grows supply with no caller guard in its own body.
func checkUnrestrictedMint(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleUnrestrictedMint)
	mintEvidence := []string{"IssueCoin", "Supply", "balances", "Balance"}
	var out []Finding
	for _, fn := range ps.funcs {
		if !fn.exported {
			continue
		}
		if !strings.Contains(fn.name, "Mint") {
			continue
		}
		if ps.bodyHasAny(fn, guardTokens) {
			continue
		}
		if !ps.bodyHasAny(fn, mintEvidence) {
			continue
		}
		desc := "Function " + fn.name + " mints new coins with no caller check in its own body. Restrict minting to an authorized minter or owner, and cap total supply where the design allows it. A guard in a wrapper function does not count for this check."
		out = append(out, newFinding(rule, fn.start, ps.raw[fn.start-1], desc))
	}
	return out
}

// CheckAdminBackdoor runs rule RC-03 on src.
func CheckAdminBackdoor(src string) []Finding {
	return checkAdminBackdoor(parseSource(src))
}

// checkAdminBackdoor implements RC-03: a single admin or owner can drain
// funds or rewrite state, and the path has no timelock or multi-signature
// check. Two shapes are covered. The stored-admin shape: a package-level
// admin or owner variable is mentioned on the drain path of a function
// that calls SendCoins or Withdraw. The hard-coded shape: a package-level
// admin or owner constant initialized with an address literal is the guard
// on a function that drains funds or rewrites persistent state, so the
// single hard-coded key is the only access control on that path. This is
// a design level finding: the code may be intentional, but one key
// controls the funds, so it must be reviewed.
func checkAdminBackdoor(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleAdminBackdoor)
	drain := []string{"SendCoins", "Withdraw"}
	adminMention := []string{"admin", "Admin", "owner", "Owner"}
	var out []Finding
	for _, fn := range ps.funcs {
		if !fn.exported {
			continue
		}
		if ps.bodyHasAny(fn, timelockTokens) || ps.bodyHasAny(fn, multisigTokens) {
			continue
		}
		line := 0
		if len(ps.adminVars) > 0 {
			if l := ps.firstLineWith(fn, drain); l != 0 && ps.bodyHasAny(fn, adminMention) {
				line = l
			}
		}
		if line == 0 && len(ps.adminConsts) > 0 {
			line = ps.firstHardcodedAdminDrain(fn)
		}
		if line == 0 {
			continue
		}
		desc := "Function " + fn.name + " lets a single stored or hard-coded admin or owner drain funds or rewrite state, with no timelock or multi-signature check on the path. Consider a timelock, a multi-signature threshold, or a capped withdrawal before deploying with real funds."
		out = append(out, newFinding(rule, line, ps.raw[line-1], desc))
	}
	return out
}

// firstHardcodedAdminDrain returns the line of the first drain or
// persistent state rewrite in fn, when fn compares a value against a
// hard-coded admin or owner constant, or 0 otherwise. A drain is a
// SendCoins or Withdraw call. A rewrite is an assignment to a
// package-level variable or a Set, Delete, or Remove call. Append lines
// are skipped: unbounded appends belong to RC-04, not to this rule.
func (ps *parsedSource) firstHardcodedAdminDrain(fn funcSpan) int {
	guarded := false
	for _, name := range ps.adminConsts {
		if ps.bodyComparesAgainst(fn, name) {
			guarded = true
			break
		}
	}
	if !guarded {
		return 0
	}
	drain := []string{"SendCoins", "Withdraw"}
	if line := ps.firstLineWith(fn, drain); line != 0 {
		return line
	}
	mutateTokens := []string{".Set(", ".Delete(", ".Remove("}
	for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
		line := ps.bodyLine(fn, i)
		if strings.Contains(line, "append(") {
			continue
		}
		if containsAny(line, mutateTokens) {
			return i + 1
		}
		if ps.lineAssignsPkgVar(line) {
			return i + 1
		}
	}
	return 0
}

// bodyComparesAgainst reports whether any line of fn compares a value
// against name with == or !=, the shape of a guard such as
// caller != Admin.
func (ps *parsedSource) bodyComparesAgainst(fn funcSpan, name string) bool {
	for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
		line := ps.bodyLine(fn, i)
		if !strings.Contains(line, name) {
			continue
		}
		if strings.Contains(line, "==") || strings.Contains(line, "!=") {
			return true
		}
	}
	return false
}

// CheckUnboundedStorage runs rule RC-04 on src.
func CheckUnboundedStorage(src string) []Finding {
	return checkUnboundedStorage(parseSource(src))
}

// checkUnboundedStorage implements RC-04: a persistent collection, a
// package-level slice or a struct field, is appended to with no length
// check or cap token in the same function. Appends to local slices are
// not flagged, because they do not persist.
func checkUnboundedStorage(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleUnboundedStorage)
	capTokens := []string{"len(", "Max", "Limit", "limit"}
	var out []Finding
	for _, fn := range ps.funcs {
		if ps.bodyHasAny(fn, capTokens) {
			continue
		}
		for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
			line := ps.bodyLine(fn, i)
			if !strings.Contains(line, "append(") {
				continue
			}
			target := appendTarget(line)
			if target == "" {
				continue
			}
			if !isPersistentTarget(ps, target) {
				continue
			}
			desc := "Function " + fn.name + " appends to persistent collection " + target + " with no length check or cap in the same function. Add a maximum size and reject or prune entries past it, or the storage deposit grows without bound."
			out = append(out, newFinding(rule, i+1, ps.raw[i], desc))
			break
		}
	}
	return out
}

// appendTarget returns the first argument of the append call on line,
// or "" when the line has no well formed append call.
func appendTarget(line string) string {
	idx := strings.Index(line, "append(")
	if idx < 0 {
		return ""
	}
	rest := line[idx+len("append("):]
	comma := strings.Index(rest, ",")
	if comma < 0 {
		return ""
	}
	return strings.TrimSpace(rest[:comma])
}

// isPersistentTarget reports whether an append target is persistent
// state: a package-level variable, or a field access such as s.items.
func isPersistentTarget(ps *parsedSource, target string) bool {
	for _, v := range ps.pkgVars {
		if target == v {
			return true
		}
	}
	return strings.Contains(target, ".")
}

// CheckFundsWithoutCheck runs rule RC-05 on src.
func CheckFundsWithoutCheck(src string) []Finding {
	return checkFundsWithoutCheck(parseSource(src))
}

// checkFundsWithoutCheck implements RC-05: a function reads coins sent
// with the transaction through OriginSend but never verifies the amount
// with AmountOf, IsGTE, IsEqual, IsPositive, IsZero, or GetCoin.
func checkFundsWithoutCheck(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleFundsWithoutCheck)
	verifyTokens := []string{
		"AmountOf", "IsGTE", "IsEqual", "IsPositive", "IsZero",
		"GetCoin", "IsNegative",
	}
	var out []Finding
	for _, fn := range ps.funcs {
		line := ps.firstLineWith(fn, []string{"OriginSend"})
		if line == 0 {
			continue
		}
		if ps.bodyHasAny(fn, verifyTokens) {
			continue
		}
		desc := "Function " + fn.name + " reads coins sent with the transaction through OriginSend but never verifies the amount. Check the received amount against the expected price or minimum with AmountOf or an IsGTE comparison before crediting anything."
		out = append(out, newFinding(rule, line, ps.raw[line-1], desc))
	}
	return out
}

// CheckWeakRandomness runs rule RC-06 on src.
func CheckWeakRandomness(src string) []Finding {
	return checkWeakRandomness(parseSource(src))
}

// checkWeakRandomness implements RC-06: block height, block time, or
// time.Now is used on the same line as modulo or a random call, which is
// the classic weak randomness shape, or is passed as an argument to a
// helper that applies modulo or a random call to that parameter. Taint
// follows parameters across calls in the same file, so a split like
// DrawNumber passing ChainHeight into DrawNumberAt, which does the
// modulo, is caught at the modulo line in the helper. Height or time used
// for a deadline comparison, with no modulo or random call, is not
// flagged. A helper defined in another file of the same realm is not
// tracked, and taint does not follow local variables: only the parameter
// itself, used directly with modulo or a random call, is flagged.
func checkWeakRandomness(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleWeakRandomness)
	sources := []string{
		"ChainHeight", "BlockHeight", "blockHeight",
		"ChainTime", "BlockTime", "blockTime",
		"time.Now", "UnixNano", "Unix()",
	}
	use := []string{"%", "rand", "Random", "Seed"}
	ps.computeTaint(sources)
	var out []Finding
	for _, fn := range ps.funcs {
		for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
			line := ps.bodyLine(fn, i)
			direct := containsAny(line, sources) && containsAny(line, use)
			tainted := false
			if !direct {
				tainted = ps.lineUsesTaintedParam(fn, line, use)
			}
			if !direct && !tainted {
				continue
			}
			var desc string
			if direct {
				desc = "Function " + fn.name + " derives a random outcome from block height, block time, or time.Now. These values are public and partly predictable, so the outcome can be anticipated. Use a commit-reveal scheme or an external verifiable randomness source instead."
			} else {
				desc = "Function " + fn.name + " receives block height, block time, or time.Now as a parameter and applies modulo or a random call to it. The caller passes a public, partly predictable value, so the outcome can be anticipated. Use a commit-reveal scheme or an external verifiable randomness source instead."
			}
			out = append(out, newFinding(rule, i+1, ps.raw[i], desc))
			break
		}
	}
	return out
}

// computeTaint marks, for every function, which of its parameters receive
// a randomness source, directly as a call argument or transitively
// through another tainted parameter. It runs to a fixed point, capped at
// eight passes, so it always terminates. A call is only tracked when its
// callee is defined in the same audited source; calls into other files or
// packages are not followed.
func (ps *parsedSource) computeTaint(sources []string) {
	byName := make(map[string]int, len(ps.funcs))
	for i, fn := range ps.funcs {
		if _, ok := byName[fn.name]; !ok {
			byName[fn.name] = i
		}
	}
	for pass := 0; pass < 8; pass++ {
		changed := false
		for _, fn := range ps.funcs {
			for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
				line := ps.bodyLine(fn, i)
				if !strings.Contains(line, "(") {
					continue
				}
				for _, call := range findCalls(line, byName) {
					ci := byName[call.name]
					for j, arg := range call.args {
						if j >= len(ps.funcs[ci].params) {
							break
						}
						if ps.funcs[ci].tainted[j] {
							continue
						}
						if containsAny(arg, sources) || ps.argUsesTaintedParam(fn, arg) {
							ps.funcs[ci].tainted[j] = true
							changed = true
						}
					}
				}
			}
		}
		if !changed {
			break
		}
	}
}

// callSite is one call found on a line: the callee name and its argument
// texts, split at top-level commas.
type callSite struct {
	name string
	args []string
}

// findCalls extracts the calls on line whose callee is a function defined
// in the audited source. Candidate names are the identifiers immediately
// followed by "(", looked up in the defined function names.
func findCalls(line string, byName map[string]int) []callSite {
	var out []callSite
	for i := 0; i < len(line); i++ {
		if !isIdentStart(line[i]) {
			continue
		}
		j := i
		for j < len(line) && isIdentChar(line[j]) {
			j++
		}
		name := line[i:j]
		if j >= len(line) || line[j] != '(' {
			i = j
			continue
		}
		if _, ok := byName[name]; !ok {
			i = j
			continue
		}
		args, end := parseCallArgs(line, j)
		if end < 0 {
			i = j
			continue
		}
		out = append(out, callSite{name: name, args: args})
		i = end
	}
	return out
}

// parseCallArgs parses the argument list starting at the "(" at pos in
// line, returning the argument texts and the index just past the matching
// ")", or -1 when the call is not closed on this line.
func parseCallArgs(line string, pos int) ([]string, int) {
	depth := 0
	for i := pos; i < len(line); i++ {
		switch line[i] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				inner := line[pos+1 : i]
				if strings.TrimSpace(inner) == "" {
					return nil, i + 1
				}
				return splitTopLevel(inner, ','), i + 1
			}
		}
	}
	return nil, -1
}

// argUsesTaintedParam reports whether arg mentions, as a whole
// identifier, one of fn's tainted parameters.
func (ps *parsedSource) argUsesTaintedParam(fn funcSpan, arg string) bool {
	for k, name := range fn.params {
		if k < len(fn.tainted) && fn.tainted[k] && lineHasIdent(arg, name) {
			return true
		}
	}
	return false
}

// lineUsesTaintedParam reports whether line applies a randomness use
// (modulo or a random call) to one of fn's tainted parameters.
func (ps *parsedSource) lineUsesTaintedParam(fn funcSpan, line string, use []string) bool {
	if !containsAny(line, use) {
		return false
	}
	for k, name := range fn.params {
		if k < len(fn.tainted) && fn.tainted[k] && lineHasIdent(line, name) {
			return true
		}
	}
	return false
}

// lineHasIdent reports whether name appears in line as a whole
// identifier, bounded by characters that cannot be part of an identifier.
func lineHasIdent(line string, name string) bool {
	if name == "" {
		return false
	}
	for i := 0; i+len(name) <= len(line); i++ {
		if line[i:i+len(name)] != name {
			continue
		}
		if i > 0 && isIdentChar(line[i-1]) {
			continue
		}
		after := i + len(name)
		if after < len(line) && isIdentChar(line[after]) {
			continue
		}
		return true
	}
	return false
}

func containsAny(line string, tokens []string) bool {
	for _, tok := range tokens {
		if strings.Contains(line, tok) {
			return true
		}
	}
	return false
}

// CheckUncheckedExternalCall runs rule RC-07 on src.
func CheckUncheckedExternalCall(src string) []Finding {
	return checkUncheckedCall(parseSource(src))
}

// checkUncheckedCall implements RC-07: a cross-realm call made as a
// bare statement, with no assignment and no error mention on the line,
// so its return value and failure are ignored. Assigned calls and calls
// in an if or return statement count as handled for this check.
func checkUncheckedCall(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RuleUncheckedCall)
	var out []Finding
	for _, fn := range ps.funcs {
		for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
			line := ps.bodyLine(fn, i)
			if !strings.Contains(line, "cross(") {
				continue
			}
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "if ") || strings.HasPrefix(trimmed, "return ") {
				continue
			}
			if strings.Contains(line, "=") || strings.Contains(line, "err") {
				continue
			}
			desc := "Function " + fn.name + " calls another realm through cross() as a bare statement and ignores the result. Capture the return value and handle the error, or a failure in the other realm passes silently."
			out = append(out, newFinding(rule, i+1, ps.raw[i], desc))
			break
		}
	}
	return out
}

// CheckPublicStateMutation runs rule RC-08 on src.
func CheckPublicStateMutation(src string) []Finding {
	return checkPublicMutation(parseSource(src))
}

// checkPublicMutation implements RC-08: an exported function mutates
// realm state, through a package-level variable assignment or a Set,
// Delete, or Remove call, with no caller guard in its own body.
// Functions already covered by the funds, mint, and backdoor rules are
// skipped, and append growth is left to RC-04. A method that only
// mutates its own receiver, such as ps.Set on a Proposals value, does not
// count: the receiver is a value the caller already holds, so the call
// rewrites the caller's own instance, not shared realm state. A method
// that assigns a package-level variable or calls Set on shared state
// still counts.
func checkPublicMutation(ps *parsedSource) []Finding {
	rule := ruleByIDMust(RulePublicMutation)
	skipNames := []string{"Mint", "Withdraw", "Transfer", "Drain"}
	var out []Finding
	for _, fn := range ps.funcs {
		if !fn.exported {
			continue
		}
		if fn.name == "Render" {
			continue
		}
		if containsAny(fn.name, skipNames) {
			continue
		}
		if ps.bodyHasAny(fn, guardTokens) {
			continue
		}
		line := 0
		for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
			body := ps.bodyLine(fn, i)
			if strings.Contains(body, "append(") {
				continue
			}
			if ps.lineHasNonReceiverMutation(fn, body) {
				line = i + 1
				break
			}
			if ps.lineAssignsPkgVar(body) {
				line = i + 1
				break
			}
		}
		if line == 0 {
			continue
		}
		desc := "Function " + fn.name + " mutates realm state but contains no caller check in its own body. Add a caller guard, or make the function non-exported when only other realm code should call it."
		out = append(out, newFinding(rule, line, ps.raw[line-1], desc))
	}
	return out
}

// lineHasNonReceiverMutation reports whether line calls Set, Delete, or
// Remove on anything other than the method receiver. The target is the
// identifier segment immediately before the dot, so ps.Set counts as a
// receiver call while store.Set and settings.Set do not.
func (ps *parsedSource) lineHasNonReceiverMutation(fn funcSpan, line string) bool {
	mutateTokens := []string{".Set(", ".Delete(", ".Remove("}
	for _, tok := range mutateTokens {
		start := 0
		for {
			rel := strings.Index(line[start:], tok)
			if rel < 0 {
				break
			}
			pos := start + rel
			if !ps.mutationTargetsReceiver(fn, line, pos) {
				return true
			}
			start = pos + len(tok)
		}
	}
	return false
}

// mutationTargetsReceiver reports whether the mutate call whose dot is at
// pos in line is a call on the method receiver, such as ps.Set(. The
// target is the identifier segment immediately before the dot.
func (ps *parsedSource) mutationTargetsReceiver(fn funcSpan, line string, pos int) bool {
	if fn.receiverVar == "" || pos == 0 {
		return false
	}
	end := pos
	start := end
	for start > 0 && isIdentChar(line[start-1]) {
		start--
	}
	return line[start:end] == fn.receiverVar
}
