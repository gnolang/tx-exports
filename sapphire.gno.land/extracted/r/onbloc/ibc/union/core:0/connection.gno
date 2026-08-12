package core

import (
	"gno.land/p/onbloc/ibc/union/types"
	"gno.land/r/onbloc/ibc/union/access"
)

func ConnectionOpenInit(cur realm, msg types.MsgConnectionOpenInit) {
	access.AssertCanCall(0, cur, SelectorConnectionOpenInit)
	mustGetImpl().ConnectionOpenInit(0, cur, msg)
}

func ConnectionOpenTry(cur realm, msg types.MsgConnectionOpenTry) {
	access.AssertCanCall(0, cur, SelectorConnectionOpenTry)
	mustGetImpl().ConnectionOpenTry(0, cur, msg)
}

func ForceConnectionOpenTry(cur realm, msg types.MsgConnectionOpenTry) {
	access.AssertCanCall(0, cur, SelectorForceConnectionTry)
	mustGetImpl().ForceConnectionOpenTry(0, cur, msg)
}

func ConnectionOpenAck(cur realm, msg types.MsgConnectionOpenAck) {
	access.AssertCanCall(0, cur, SelectorConnectionOpenAck)
	mustGetImpl().ConnectionOpenAck(0, cur, msg)
}

func ForceConnectionOpenAck(cur realm, msg types.MsgConnectionOpenAck) {
	access.AssertCanCall(0, cur, SelectorForceConnectionAck)
	mustGetImpl().ForceConnectionOpenAck(0, cur, msg)
}

func ConnectionOpenConfirm(cur realm, msg types.MsgConnectionOpenConfirm) {
	access.AssertCanCall(0, cur, SelectorConnectionOpenConfirm)
	mustGetImpl().ConnectionOpenConfirm(0, cur, msg)
}

func ForceConnectionOpenConfirm(cur realm, msg types.MsgConnectionOpenConfirm) {
	access.AssertCanCall(0, cur, SelectorForceConnectionConfirm)
	mustGetImpl().ForceConnectionOpenConfirm(0, cur, msg)
}

