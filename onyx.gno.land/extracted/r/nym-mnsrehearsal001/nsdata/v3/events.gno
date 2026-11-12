package nsdata

import (
	"strconv"

	"chain"
)

/*
EVERY RECORD AND CONFIG CHANGE EMITS, FROM THE VAULT.

There were no events here outside governance, and none in the logic realm
at all, so the audit's stolen-admin attacks were invisible until the
ledger's Burn and Mint showed the result (audit M-6). PREFLIGHT.md and
MAINNET.md make monitoring the mitigation — "a timelock is worthless if
nobody watches it" — and there was nothing to watch.

They are emitted here rather than in nslogic so the coverage survives a
logic swap: whatever realm writes, the vault says what changed. Each one
carries `by`, the realm that made the write. For record writes that is a
trusted logic realm, which is the point — a write from a realm a monitor
did not expect IS the incident. nslogic adds its own AdminAction event with
the signer and the call.

Profile writes name the field and never the value: the value is in the
transaction already, and an event index is not the place to collect
people's addresses a second time.
*/

func emitBy(cur realm, typ string, kv ...string) {
	kv = append(kv, "by", cur.Previous().Address().String())
	chain.Emit(typ, kv...)
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// emitConfig is the one event for every typed vault setting.
func emitConfig(cur realm, key, value string) {
	emitBy(cur, "ConfigSet", "key", key, "value", value)
}
