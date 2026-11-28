package bouncer

// Guidance is the fix guidance for one rule. It is written once per rule,
// so every Passport says the same thing and it costs nothing per finding.
type Guidance struct {
	Title      string // short name of the bug class
	Severity   string // as the scanner reports it
	Guide      string // security guide sections
	Vulnerable string // the bug, as Gno code (Wanted poster)
	Meaning    string // what the finding means
	Danger     string // why it is dangerous
	Fix        string // what to change
	Example    string // the fixed code, Gno
	Why        string // why the fix works
}

// RuleGuidance returns the guidance for rule, and false for a rule this
// realm has no guidance for yet.
func RuleGuidance(rule string) (Guidance, bool) {
	switch rule {
	case "B01":
		return Guidance{
			Title:      "Getter returns a pointer into state",
			Severity:   SeverityHigh,
			Vulnerable: "var ledger = avl.NewTree() // address -> balance\n\n// Ledger hands out the live tree.\nfunc Ledger() *avl.Tree {\n\treturn ledger\n}\n\n// Any realm, any time:\n//   vault.Ledger().Set(attacker, int64(1_000_000))",
			Guide:      "§5.1, §5.1a",
			Meaning:    "An exported function hands out a pointer to the realm's own state, and the pointed-to type has an exported method that changes it.",
			Danger:     "Readonly taint stops another realm writing fields through the pointer, but not calling methods on it. Any realm can call the mutating method, and the write commits with this realm's authority: balances, owners and counters change with no check at all.",
			Fix:        "Return copies or plain values, never a pointer into package state. Keep mutating methods unexported and reach them only through crossing functions that check the caller.",
			Example:    "type Entry struct {\n\tAddr    address\n\tBalance int64\n}\n\n// Balances returns a copy of the ledger.\nfunc Balances() []Entry {\n\tout := []Entry{}\n\tledger.Iterate(\"\", \"\", func(k string, v any) bool {\n\t\tout = append(out, Entry{address(k), v.(int64)})\n\t\treturn false\n\t})\n\treturn out\n}",
			Why:        "A copy has no path back into the realm's storage, so nothing a caller does to it can reach the real state.",
		}, true
	case "B05":
		return Guidance{
			Title:      "IsUser() guards an OriginSend payment",
			Severity:   SeverityCritical,
			Vulnerable: "func Deposit(cur realm) {\n\tif !cur.Previous().IsUser() { // also true for maketx run\n\t\tpanic(\"users only\")\n\t}\n\tamount := unsafe.OriginSend().AmountOf(\"ugnot\")\n\tcredit(cur.Previous().Address(), amount) // coins may never have arrived\n}",
			Guide:      "§5.5",
			Meaning:    "A payment is credited from `OriginSend()` behind an `IsUser()` check.",
			Danger:     "`IsUser()` is also true for a `maketx run` script. In that case the coins in `OriginSend()` go to the script's own realm, not to this one, so the caller is credited for money this realm never received and can withdraw other users' funds.",
			Fix:        "Accept payments only from a direct call: check `cur.Previous().IsUserCall()` before reading `OriginSend()`.",
			Example:    "func Deposit(cur realm) {\n\tif !cur.IsCurrent() {\n\t\tpanic(\"not current\")\n\t}\n\tif !cur.Previous().IsUserCall() {\n\t\tpanic(\"deposit with maketx call\")\n\t}\n\tamount := unsafe.OriginSend().AmountOf(\"ugnot\")\n\t// credit amount\n}",
			Why:        "`IsUserCall()` is true only for a direct `maketx call`, where the sent coins are guaranteed to land at this realm before it runs.",
		}, true
	case "B03":
		return Guidance{
			Title:      "Caller-supplied callback runs with the realm's authority",
			Severity:   SeverityCritical,
			Vulnerable: "var scores = map[string]int64{}\n\n// Report lets the caller format the live map.\nfunc Report(cur realm, format func(map[string]int64) string) string {\n\treturn format(scores) // a /p/ function runs as this realm here\n}",
			Guide:      "§3C, §5.3",
			Meaning:    "The realm calls a function value its caller passed in, and hands it a map, slice, pointer or other reference.",
			Danger:     "A top-level function from a /p/ package does not switch realms when called, so inside this call it runs as this realm and can write whatever it is handed, such as the live balances map.",
			Fix:        "Do not call caller-supplied functions. If you must, type the callback with a type declared in this realm, which /p/ code cannot name, and hand it a copy.",
			Example:    "type Entry struct {\n\tPlayer string\n\tPoints int64\n}\n\nfunc Report(cur realm, format func(rows []Entry) string) string {\n\tif !cur.IsCurrent() {\n\t\tpanic(\"not current\")\n\t}\n\treturn format(copyRows())\n}",
			Why:        "A /p/ package cannot import a realm, so it cannot supply a func([]Entry); a function from another realm, or a closure, runs under its own realm and cannot write this realm's data.",
		}, true
	case "B04":
		return Guidance{
			Title:      "unsafe.PreviousRealm() in a crossing function",
			Severity:   SeverityMedium,
			Guide:      "§5.8",
			Vulnerable: "import \"chain/runtime/unsafe\"\n\nfunc Sign(cur realm) {\n\tsigner := unsafe.PreviousRealm().Address() // skips the frame check\n\tsigners = append(signers, signer)\n}",
			Meaning:    "A crossing function takes its caller from `unsafe.PreviousRealm()` instead of `cur.Previous()`.",
			Danger:     "`cur` is the capability the runtime minted for this exact call frame; `unsafe.PreviousRealm()` bypasses the `cur.IsCurrent()` frame verification that makes `cur.Previous()` trustworthy, so caller identity rests on an unchecked API.",
			Fix:        "Check `cur.IsCurrent()`, then take the caller from `cur.Previous()`.",
			Example:    "func Sign(cur realm) {\n\tif !cur.IsCurrent() {\n\t\tpanic(\"not current\")\n\t}\n\tsigners = append(signers, cur.Previous().Address())\n}",
			Why:        "`cur.IsCurrent()` proves `cur` belongs to this frame, so `cur.Previous()` is the realm that really called.",
		}, true
	case "B08":
		return Guidance{
			Title:      "A realm value stored in state",
			Severity:   SeverityMedium,
			Guide:      "§5.7",
			Vulnerable: "var lastVisitor realm\n\nfunc Visit(cur realm) {\n\tlastVisitor = cur.Previous() // cannot be persisted\n}",
			Meaning:    "A `realm` value is written into a package variable, a field or a map.",
			Danger:     "Realm values are tied to one call frame and cannot be persisted: the transaction panics at finalize, so the function always fails, and anything that depends on it is stuck.",
			Fix:        "Store the realm's `Address()` or `PkgPath()`, which are plain values.",
			Example:    "var lastVisitor address\n\nfunc Visit(cur realm) {\n\tif !cur.IsCurrent() {\n\t\tpanic(\"not current\")\n\t}\n\tlastVisitor = cur.Previous().Address()\n}",
			Why:        "An address is plain data: it can be stored and compared across transactions.",
		}, true
	case "B10":
		return Guidance{
			Title:      "Imports the test20 test token",
			Severity:   SeverityCritical,
			Guide:      "§4",
			Vulnerable: "import \"gno.land/r/tests/vm/test20\"\n\nfunc IsVIP(addr address) bool {\n\treturn test20.Token.BalanceOf(addr) >= 1000\n}\n\n// Anyone, any time:\n//   test20.PrivateLedger.Mint(attacker, 1000)",
			Meaning:    "The package imports `gno.land/r/tests/vm/test20`, a token made for tests.",
			Danger:     "test20 exports its `PrivateLedger` on purpose, so anyone can mint, burn or move its balances. Anything that counts test20 balances can be faked.",
			Fix:        "Use a real token, or create your own with `gno.land/p/nt/grc20` and keep its `*PrivateLedger` in a lowercase variable.",
			Example:    "var (\n\ttoken  *grc20.Token\n\tledger *grc20.PrivateLedger // lowercase: only this realm mints\n)\n\nfunc init(cur realm) {\n\ttoken, ledger = grc20.NewToken(\"Lounge\", \"LNG\", 4, 0, cur)\n}",
			Why:        "Only this realm can reach its own ledger, so only it can mint.",
		}, true
	case "B09":
		return Guidance{
			Title:    "External Teller used without IsCanonicalTeller",
			Severity: SeverityHigh,
			Guide:    "§5.4",
			Meaning:  "The realm calls a GRC20 Teller that a caller passed in, without checking it.",
			Danger:   "A fake Teller can report transfers that never happened.",
			Fix:      "Check `grc20.IsCanonicalTeller(t)` before using a Teller from a caller, or look the token up yourself.",
			Example:  "",
			Why:      "A canonical Teller is the token's own, so its transfers are real.",
		}, true
	}
	return Guidance{}, false
}
