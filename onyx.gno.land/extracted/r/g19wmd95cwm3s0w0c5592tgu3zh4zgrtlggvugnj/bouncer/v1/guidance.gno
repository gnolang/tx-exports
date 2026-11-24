package bouncer

// Guidance is the fix guidance for one rule. It is written once per rule,
// so every Passport says the same thing and it costs nothing per finding.
type Guidance struct {
	Title   string // short name of the bug class
	Guide   string // security guide sections
	Meaning string // what the finding means
	Danger  string // why it is dangerous
	Fix     string // what to change
	Example string // the fixed code, Gno
	Why     string // why the fix works
}

// RuleGuidance returns the guidance for rule, and false for a rule this
// realm has no guidance for yet.
func RuleGuidance(rule string) (Guidance, bool) {
	switch rule {
	case "B01":
		return Guidance{
			Title:   "Getter returns a pointer into state",
			Guide:   "§5.1, §5.1a",
			Meaning: "An exported function hands out a pointer to the realm's own state, and the pointed-to type has an exported method that changes it.",
			Danger:  "Readonly taint stops another realm writing fields through the pointer, but not calling methods on it. Any realm can call the mutating method, and the write commits with this realm's authority: balances, owners and counters change with no check at all.",
			Fix:     "Return copies or plain values, never a pointer into package state. Keep mutating methods unexported and reach them only through crossing functions that check the caller.",
			Example: "type Entry struct {\n\tAddr    address\n\tBalance int64\n}\n\n// Balances returns a copy of the ledger.\nfunc Balances() []Entry {\n\tout := []Entry{}\n\tledger.Iterate(\"\", \"\", func(k string, v any) bool {\n\t\tout = append(out, Entry{address(k), v.(int64)})\n\t\treturn false\n\t})\n\treturn out\n}",
			Why:     "A copy has no path back into the realm's storage, so nothing a caller does to it can reach the real state.",
		}, true
	case "B05":
		return Guidance{
			Title:   "IsUser() guards an OriginSend payment",
			Guide:   "§5.5",
			Meaning: "A payment is credited from `OriginSend()` behind an `IsUser()` check.",
			Danger:  "`IsUser()` is also true for a `maketx run` script. In that case the coins in `OriginSend()` go to the script's own realm, not to this one, so the caller is credited for money this realm never received and can withdraw other users' funds.",
			Fix:     "Accept payments only from a direct call: check `cur.Previous().IsUserCall()` before reading `OriginSend()`.",
			Example: "func Deposit(cur realm) {\n\tif !cur.IsCurrent() {\n\t\tpanic(\"not current\")\n\t}\n\tif !cur.Previous().IsUserCall() {\n\t\tpanic(\"deposit with maketx call\")\n\t}\n\tamount := unsafe.OriginSend().AmountOf(\"ugnot\")\n\t// credit amount\n}",
			Why:     "`IsUserCall()` is true only for a direct `maketx call`, where the sent coins are guaranteed to land at this realm before it runs.",
		}, true
	case "B03":
		return Guidance{
			Title:   "Caller-supplied callback runs with the realm's authority",
			Guide:   "§3C, §5.3",
			Meaning: "The realm calls a function or interface value that its caller passed in.",
			Danger:  "The callback runs while this realm holds its authority, so it can do anything this realm can: move its coins, or call back in mid-update.",
			Fix:     "Never invoke a caller-supplied function or interface while holding this realm's authority. Take plain data instead.",
			Example: "",
			Why:     "Plain data cannot run code, so there is nothing to hijack.",
		}, true
	case "B09":
		return Guidance{
			Title:   "External Teller used without IsCanonicalTeller",
			Guide:   "§5.4",
			Meaning: "The realm calls a GRC20 Teller that a caller passed in, without checking it.",
			Danger:  "A fake Teller can report transfers that never happened.",
			Fix:     "Check `grc20.IsCanonicalTeller(t)` before using a Teller from a caller, or look the token up yourself.",
			Example: "",
			Why:     "A canonical Teller is the token's own, so its transfers are real.",
		}, true
	}
	return Guidance{}, false
}
