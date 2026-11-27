// Package auditrules is a pure, stateless Gnolang package that audits the
// source text of a Gno.land realm and returns deterministic findings.
//
// It does not read chain state, it does not call other realms, and it does
// not depend on any realm package. The rules are lexical: they scan source
// text line by line, track function spans and brace depth, and look for
// known risky shapes. They are signals, not proofs. A finding means "a
// human should look at this line", and a clean result means "no known
// shape was found", not "this realm is safe".
//
// The package deliberately uses only the strings and strconv standard
// libraries. See README.md for the full list of Gnolang limits that
// shaped this design.
package auditrules

import (
	"strconv"
	"strings"
)

// MaxSourceBytes caps the audited input. Longer sources are truncated to
// this size before scanning, so a hostile or accidental huge input cannot
// make an audit consume unbounded gas.
const MaxSourceBytes = 262144

// MaxLines caps the number of source lines scanned.
const MaxLines = 20000

// MaxFindings caps the number of findings Audit returns.
const MaxFindings = 256

// Severity grades how serious a finding is.
type Severity string

const (
	// SeverityCritical marks a finding that can directly lose funds or
	// hand full control of a realm to one party.
	SeverityCritical Severity = "critical"
	// SeverityHigh marks a finding that can lose funds or break access
	// control when the flagged code is reachable.
	SeverityHigh Severity = "high"
	// SeverityMedium marks a finding that is risky or unfair but needs
	// extra conditions to cause harm.
	SeverityMedium Severity = "medium"
	// SeverityLow marks a finding worth fixing but unlikely to cause
	// direct harm on its own.
	SeverityLow Severity = "low"
)

// Finding is one audit result. Line is 1-based. SourceLine is the exact
// source line (trimmed) that triggered the finding, so a report can cite
// it verbatim. File is empty when the caller audited a bare source
// string; AuditFile fills it in.
type Finding struct {
	RuleID      string
	Severity    Severity
	Title       string
	Description string
	File        string
	Line        int
	SourceLine  string
}

// Report is one stored audit report. It is defined here, in the rules
// package, so the report realm, the web UI, and the agent mode all share
// one shape. Height is the block height the report was stored at.
type Report struct {
	ID         int
	RealmPath  string
	SourceHash string
	Score      int
	Auditor    string
	Height     int64
	Findings   []Finding
}

// Rule describes one audit rule in the catalog.
type Rule struct {
	ID          string
	Name        string
	Severity    Severity
	Description string
}

// Rule IDs. Keep them stable: reports stored on chain cite them.
const (
	RuleNoCallerGuard     = "RC-01"
	RuleUnrestrictedMint  = "RC-02"
	RuleAdminBackdoor     = "RC-03"
	RuleUnboundedStorage  = "RC-04"
	RuleFundsWithoutCheck = "RC-05"
	RuleWeakRandomness    = "RC-06"
	RuleUncheckedCall     = "RC-07"
	RulePublicMutation    = "RC-08"
)

// Rules returns the full rule catalog in ID order.
func Rules() []Rule {
	return []Rule{
		{
			ID:          RuleNoCallerGuard,
			Name:        "Sensitive function without caller check",
			Severity:    SeverityHigh,
			Description: "An exported function moves funds or changes admin state but contains no caller guard such as IsUser, IsRealm, OriginCaller, or an owner check. Any caller can invoke it.",
		},
		{
			ID:          RuleUnrestrictedMint,
			Name:        "Unrestricted mint",
			Severity:    SeverityCritical,
			Description: "A mint function issues coins or grows supply with no access control. Anyone can mint new tokens.",
		},
		{
			ID:          RuleAdminBackdoor,
			Name:        "Single admin backdoor",
			Severity:    SeverityCritical,
			Description: "A single stored or hard-coded admin or owner address can drain funds or rewrite state, and the path has no timelock or multi-signature check. One key controls the funds.",
		},
		{
			ID:          RuleUnboundedStorage,
			Name:        "Unbounded storage growth",
			Severity:    SeverityMedium,
			Description: "A persistent collection is appended to with no length check or cap in the same function. Storage, and the deposit that pays for it, can grow without bound.",
		},
		{
			ID:          RuleFundsWithoutCheck,
			Name:        "Funds accepted without a check",
			Severity:    SeverityHigh,
			Description: "A function reads coins sent with the transaction through OriginSend but never verifies the sender amount with AmountOf, IsGTE, IsEqual, or an equivalent check.",
		},
		{
			ID:          RuleWeakRandomness,
			Name:        "Weak randomness",
			Severity:    SeverityMedium,
			Description: "Block height, block time, or time.Now is used with modulo or a random call to pick a winner or outcome. Block values are public and partly miner or proposer influenced, so the outcome is predictable.",
		},
		{
			ID:          RuleUncheckedCall,
			Name:        "Unchecked external realm call",
			Severity:    SeverityMedium,
			Description: "A cross-realm call is made as a bare statement and its return value or failure is ignored. A failed call in another realm can pass silently.",
		},
		{
			ID:          RulePublicMutation,
			Name:        "Public state mutation without guard",
			Severity:    SeverityHigh,
			Description: "An exported function mutates realm state with no caller guard at all. Anyone can rewrite that state.",
		},
	}
}

// RuleByID returns the catalog entry for id, or false when id is unknown.
func RuleByID(id string) (Rule, bool) {
	for _, r := range Rules() {
		if r.ID == id {
			return r, true
		}
	}
	return Rule{}, false
}

// SeverityWeight is the score cost of one finding of the given severity.
func SeverityWeight(s Severity) int {
	switch s {
	case SeverityCritical:
		return 25
	case SeverityHigh:
		return 15
	case SeverityMedium:
		return 8
	case SeverityLow:
		return 3
	default:
		return 0
	}
}

// Score turns findings into a 0 to 100 risk score. 100 means no findings.
// Each finding subtracts its severity weight, and the result never goes
// below 0. The score is deterministic: same source, same score.
func Score(findings []Finding) int {
	score := 100
	for _, f := range findings {
		score -= SeverityWeight(f.Severity)
	}
	if score < 0 {
		score = 0
	}
	return score
}

// Audit audits one realm source text and returns its findings in rule
// order, then line order. The input is capped at MaxSourceBytes.
func Audit(src string) []Finding {
	return AuditFile("", src)
}

// AuditFile is Audit with a file name attached to every finding, so a
// report can cite the file the line came from.
func AuditFile(file string, src string) []Finding {
	ps := parseSource(src)
	out := make([]Finding, 0, 16)
	out = append(out, checkNoCallerGuard(ps)...)
	out = append(out, checkUnrestrictedMint(ps)...)
	out = append(out, checkAdminBackdoor(ps)...)
	out = append(out, checkUnboundedStorage(ps)...)
	out = append(out, checkFundsWithoutCheck(ps)...)
	out = append(out, checkWeakRandomness(ps)...)
	out = append(out, checkUncheckedCall(ps)...)
	out = append(out, checkPublicMutation(ps)...)
	for i := range out {
		out[i].File = file
	}
	out = dedupeFindings(out)
	if len(out) > MaxFindings {
		out = out[:MaxFindings]
	}
	return out
}

func dedupeFindings(in []Finding) []Finding {
	seen := make(map[string]bool)
	out := make([]Finding, 0, len(in))
	for _, f := range in {
		key := f.RuleID + ":" + strconv.Itoa(f.Line)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, f)
	}
	return out
}

func newFinding(rule Rule, line int, rawLine string, desc string) Finding {
	return Finding{
		RuleID:      rule.ID,
		Severity:    rule.Severity,
		Title:       rule.Name,
		Description: desc,
		Line:        line,
		SourceLine:  strings.TrimSpace(rawLine),
	}
}

func ruleByIDMust(id string) Rule {
	r, _ := RuleByID(id)
	return r
}

// funcSpan is one top-level function or method in the audited source.
// Start and End are 1-based inclusive line numbers. Receiver is the
// receiver type name for a method, or "" for a plain function. Params
// are the parameter names in order, and Tainted marks the parameters
// that receive a randomness source through a call (RC-06 taint).
type funcSpan struct {
	name        string
	start       int
	end         int
	exported    bool
	receiver    string
	receiverVar string
	params      []string
	tainted     []bool
}

// parsedSource is the audited source after cleaning and structure scan.
type parsedSource struct {
	raw           []string
	clean         []string
	funcs         []funcSpan
	pkgVars       []string
	adminVars     []string
	adminConsts   []string
	adminAddrLine int
}

// parseSource splits src into lines, blanks out comments and string
// contents for matching (the raw lines are kept for excerpts), then
// records top-level functions and package-level variables.
func parseSource(src string) *parsedSource {
	if len(src) > MaxSourceBytes {
		src = src[:MaxSourceBytes]
	}
	raw := strings.Split(src, "\n")
	if len(raw) > MaxLines {
		raw = raw[:MaxLines]
	}
	ps := &parsedSource{
		raw:   raw,
		clean: make([]string, len(raw)),
	}
	inBlock := false
	inRaw := false
	for i, line := range raw {
		ps.clean[i] = cleanLine(line, &inBlock, &inRaw)
	}
	ps.scanStructure()
	return ps
}

// cleanLine returns a copy of line with comments and string or rune
// literal contents replaced by spaces. Positions are preserved, so
// brace counting and keyword search on the result cannot be fooled by
// a keyword sitting inside a comment or a string literal. inBlock and
// inRaw carry block comment and raw string state across lines.
func cleanLine(line string, inBlock *bool, inRaw *bool) string {
	out := []byte(line)
	i := 0
	for i < len(out) {
		if *inRaw {
			if out[i] == '`' {
				*inRaw = false
			} else {
				out[i] = ' '
			}
			i++
			continue
		}
		if *inBlock {
			if out[i] == '*' && i+1 < len(out) && out[i+1] == '/' {
				out[i] = ' '
				out[i+1] = ' '
				*inBlock = false
				i += 2
				continue
			}
			out[i] = ' '
			i++
			continue
		}
		c := out[i]
		if c == '`' {
			*inRaw = true
			out[i] = ' '
			i++
			continue
		}
		if c == '"' {
			out[i] = ' '
			i++
			for i < len(out) {
				if out[i] == '\\' {
					out[i] = ' '
					if i+1 < len(out) {
						out[i+1] = ' '
					}
					i += 2
					continue
				}
				if out[i] == '"' {
					out[i] = ' '
					i++
					break
				}
				out[i] = ' '
				i++
			}
			continue
		}
		if c == '\'' {
			out[i] = ' '
			i++
			for i < len(out) {
				if out[i] == '\\' {
					out[i] = ' '
					if i+1 < len(out) {
						out[i+1] = ' '
					}
					i += 2
					continue
				}
				if out[i] == '\'' {
					out[i] = ' '
					i++
					break
				}
				out[i] = ' '
				i++
			}
			continue
		}
		if c == '/' && i+1 < len(out) && out[i+1] == '/' {
			for ; i < len(out); i++ {
				out[i] = ' '
			}
			break
		}
		if c == '/' && i+1 < len(out) && out[i+1] == '*' {
			out[i] = ' '
			out[i+1] = ' '
			*inBlock = true
			i += 2
			continue
		}
		i++
	}
	return string(out)
}

func countBraces(line string) int {
	depth := 0
	for i := 0; i < len(line); i++ {
		if line[i] == '{' {
			depth++
		} else if line[i] == '}' {
			depth--
		}
	}
	return depth
}

func isExported(name string) bool {
	if len(name) == 0 {
		return false
	}
	return name[0] >= 'A' && name[0] <= 'Z'
}

// parseFuncName extracts the function name from a trimmed line that
// starts with "func ". It handles methods with a receiver in parens.
func parseFuncName(trimmed string) (string, bool) {
	rest := strings.TrimSpace(trimmed[len("func "):])
	if strings.HasPrefix(rest, "(") {
		idx := strings.Index(rest, ")")
		if idx < 0 {
			return "", false
		}
		rest = strings.TrimSpace(rest[idx+1:])
	}
	end := strings.Index(rest, "(")
	if end < 0 {
		return "", false
	}
	name := strings.TrimSpace(rest[:end])
	if name == "" {
		return "", false
	}
	return name, true
}

// parseFuncReceiver extracts the receiver variable name and type name
// from a trimmed line that starts with "func (", or "" and "" for a plain
// function. The type is the last field inside the receiver parens, with a
// leading * stripped and a package qualifier removed, so
// (ps *Proposals) yields variable ps and type Proposals. An unnamed
// receiver yields "" for the variable name.
func parseFuncReceiver(trimmed string) (string, string) {
	rest := strings.TrimSpace(trimmed[len("func "):])
	if !strings.HasPrefix(rest, "(") {
		return "", ""
	}
	idx := strings.Index(rest, ")")
	if idx < 0 {
		return "", ""
	}
	inner := strings.TrimSpace(rest[1:idx])
	if inner == "" {
		return "", ""
	}
	fields := strings.Fields(inner)
	typ := fields[len(fields)-1]
	typ = strings.TrimPrefix(typ, "*")
	if dot := strings.LastIndex(typ, "."); dot >= 0 {
		typ = typ[dot+1:]
	}
	if len(fields) == 1 {
		return "", typ
	}
	return fields[0], typ
}

// builtinTypeNames are single-word parameter spellings that name a type,
// not a parameter, so `func Foo(int, string)` records no parameters.
var builtinTypeNames = map[string]bool{
	"int": true, "int8": true, "int16": true, "int32": true, "int64": true,
	"uint": true, "uint8": true, "uint16": true, "uint32": true, "uint64": true,
	"string": true, "bool": true, "byte": true, "rune": true,
	"float32": true, "float64": true, "error": true, "address": true,
	"realm": true, "any": true,
}

// parseFuncParams extracts the parameter names of the function declared
// on trimmed, in order. It returns nil for a multi-line signature, whose
// closing paren is not on this line, and for a function with no named
// parameters. Grouped names (a, b int) and variadic parameters are
// handled; unnamed parameters are skipped. A single-word part that starts
// with an uppercase letter is a type name, not a parameter name, so an
// unnamed parameter of a named type is skipped too.
func parseFuncParams(trimmed string) []string {
	rest := strings.TrimSpace(trimmed[len("func "):])
	if strings.HasPrefix(rest, "(") {
		idx := strings.Index(rest, ")")
		if idx < 0 {
			return nil
		}
		rest = strings.TrimSpace(rest[idx+1:])
	}
	open := strings.Index(rest, "(")
	if open < 0 {
		return nil
	}
	depth := 0
	close := -1
	for i := open; i < len(rest); i++ {
		if rest[i] == '(' {
			depth++
		} else if rest[i] == ')' {
			depth--
			if depth == 0 {
				close = i
				break
			}
		}
	}
	if close < 0 {
		return nil
	}
	inner := rest[open+1 : close]
	if strings.TrimSpace(inner) == "" {
		return nil
	}
	var params []string
	for _, part := range splitTopLevel(inner, ',') {
		fields := strings.Fields(part)
		if len(fields) == 0 {
			continue
		}
		name := strings.TrimPrefix(fields[0], "*")
		if len(fields) == 1 {
			if builtinTypeNames[name] {
				continue
			}
			if len(name) > 0 && name[0] >= 'A' && name[0] <= 'Z' {
				continue
			}
		}
		params = append(params, name)
	}
	return params
}

// splitTopLevel splits s on sep, ignoring separators nested inside
// parentheses.
func splitTopLevel(s string, sep byte) []string {
	var out []string
	depth := 0
	start := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
		case sep:
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	out = append(out, s[start:])
	return out
}

// isIdentStart reports whether c can start a Go identifier.
func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// isIdentChar reports whether c can appear in a Go identifier.
func isIdentChar(c byte) bool {
	return isIdentStart(c) || (c >= '0' && c <= '9')
}

// scanStructure walks the cleaned lines once, tracking brace depth to
// find top-level functions and package-level variables.
func (ps *parsedSource) scanStructure() {
	depth := 0
	curIdx := -1
	seenBrace := false
	inDeclBlock := false
	for i := 0; i < len(ps.clean); i++ {
		trimmed := strings.TrimSpace(ps.clean[i])
		before := depth
		if curIdx == -1 && before == 0 {
			if strings.HasPrefix(trimmed, "func ") {
				if name, ok := parseFuncName(trimmed); ok {
					receiverVar, receiver := parseFuncReceiver(trimmed)
					params := parseFuncParams(trimmed)
					ps.funcs = append(ps.funcs, funcSpan{
						name:        name,
						start:       i + 1,
						end:         i + 1,
						receiver:    receiver,
						receiverVar: receiverVar,
						params:      params,
						tainted:     make([]bool, len(params)),
						// A method on an unexported type is only
						// reachable from the realm's own code, even
						// when the method name is exported, so it
						// counts as non-exported for the access
						// control rules. Note that a capitalized type
						// name is exported by this test: gov/dao
						// Proposals is capitalized, so its methods
						// stay exported here, and RC-08 clears them
						// instead because their mutations target only
						// the receiver.
						exported: isExported(name) && (receiver == "" || isExported(receiver)),
					})
					curIdx = len(ps.funcs) - 1
					seenBrace = false
				}
			} else if strings.HasPrefix(trimmed, "var (") || strings.HasPrefix(trimmed, "const (") {
				inDeclBlock = true
			} else if inDeclBlock {
				if strings.HasPrefix(trimmed, ")") {
					inDeclBlock = false
				} else {
					// Inside a var or const block the name is the
					// first field, not the second, so prepend a
					// marker to keep addPkgVar's field positions.
					fields := append([]string{"var"}, strings.Fields(trimmed)...)
					ps.addPkgVar(fields, ps.raw[i])
				}
			} else if strings.HasPrefix(trimmed, "var ") || strings.HasPrefix(trimmed, "const ") {
				ps.addPkgVar(strings.Fields(trimmed), ps.raw[i])
			}
			// The address literal lives inside a string, and string
			// contents are blanked on the cleaned line, so this check
			// must read the raw line.
			lowerRaw := strings.ToLower(ps.raw[i])
			if strings.Contains(lowerRaw, "g1") && (strings.Contains(lowerRaw, "admin") || strings.Contains(lowerRaw, "owner")) {
				if ps.adminAddrLine == 0 {
					ps.adminAddrLine = i + 1
				}
			}
		}
		depth += countBraces(ps.clean[i])
		if curIdx >= 0 {
			if strings.Contains(ps.clean[i], "{") {
				seenBrace = true
			}
			ps.funcs[curIdx].end = i + 1
			if seenBrace && depth == 0 {
				curIdx = -1
			}
		}
	}
}

// addPkgVar records a package-level variable or constant name from the
// fields of its declaration line. fields[0] is "var" or "const" and
// fields[1] is the name. Admin or owner names are also recorded
// separately for the backdoor rule. A hard-coded admin constant is an
// admin or owner name initialized with an address literal on the raw
// line: the cleaned line cannot show it, because string contents are
// blanked before scanning.
func (ps *parsedSource) addPkgVar(fields []string, rawLine string) {
	if len(fields) < 2 {
		return
	}
	name := fields[1]
	name = strings.TrimSuffix(name, ",")
	if name == "" {
		return
	}
	ps.pkgVars = append(ps.pkgVars, name)
	lower := strings.ToLower(name)
	if strings.Contains(lower, "admin") || strings.Contains(lower, "owner") {
		ps.adminVars = append(ps.adminVars, name)
		if strings.Contains(rawLine, "\"g1") {
			ps.adminConsts = append(ps.adminConsts, name)
		}
	}
}

// bodyLine returns the cleaned text of line i that belongs to the
// function body. On the signature line only the text after the opening
// brace counts, so the function name itself can never match an action
// token such as Withdraw, while a single-line function still scans its
// body. When the brace opens on a later line, the signature line
// contributes nothing.
func (ps *parsedSource) bodyLine(fn funcSpan, i int) string {
	line := ps.clean[i]
	if i == fn.start-1 {
		if idx := strings.Index(line, "{"); idx >= 0 {
			return line[idx+1:]
		}
		return ""
	}
	return line
}

// firstLineWith returns the 1-based line number of the first line in fn
// whose cleaned text contains any token, or 0 when there is none.
func (ps *parsedSource) firstLineWith(fn funcSpan, tokens []string) int {
	for i := fn.start - 1; i < fn.end && i < len(ps.clean); i++ {
		for _, tok := range tokens {
			if strings.Contains(ps.bodyLine(fn, i), tok) {
				return i + 1
			}
		}
	}
	return 0
}

// bodyHasAny reports whether any line of fn contains any token.
func (ps *parsedSource) bodyHasAny(fn funcSpan, tokens []string) bool {
	return ps.firstLineWith(fn, tokens) != 0
}

// lineAssignsPkgVar reports whether the cleaned line assigns to one of
// the package-level variables, using =, :=, +=, or -=.
func (ps *parsedSource) lineAssignsPkgVar(line string) bool {
	trimmed := strings.TrimSpace(line)
	for _, v := range ps.pkgVars {
		if strings.HasPrefix(trimmed, v+" =") ||
			strings.HasPrefix(trimmed, v+" :=") ||
			strings.HasPrefix(trimmed, v+" +=") ||
			strings.HasPrefix(trimmed, v+" -=") {
			return true
		}
	}
	return false
}
