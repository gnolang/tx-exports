package nslogic

import (
	"strconv"

	"chain"
)

/*
EVERY ADMIN ACTION EMITS AdminAction, with the signer and the call.

There was no event anywhere in this realm, so a stolen admin key's
treasury change, rate change or deletion was invisible until its effects
showed up somewhere else (audit M-4/M-6). The vault now says what changed
(nsdata/events.gno); this says who asked, through which call, with which
arguments — the line a monitor alerts on. A failed call emits nothing:
an aborted transaction keeps no events.

One event type, "AdminAction", with "fn" naming the call, so a monitor
subscribes once and a new admin call is covered without anybody updating
a list. Profile values replayed by a restore are not repeated here, only
their keys, for the reason given in nsdata/events.gno.
*/
func emitAdmin(cur realm, fn string, kv ...string) {
	attrs := []string{"fn", fn, "by", cur.Previous().Address().String()}
	chain.Emit("AdminAction", append(attrs, kv...)...)
}

func fmtInt(n int64) string { return strconv.FormatInt(n, 10) }

func fmtI(n int) string { return strconv.Itoa(n) }

func fmtBool(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
