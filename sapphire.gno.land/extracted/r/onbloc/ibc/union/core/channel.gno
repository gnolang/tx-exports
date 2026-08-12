package core

import (
	"gno.land/p/onbloc/ibc/union/types"
	"gno.land/r/onbloc/ibc/union/access"
)

func ChannelOpenInit(cur realm, msg types.MsgChannelOpenInit) {
	access.AssertCanCall(0, cur, SelectorChannelOpenInit)
	mustGetImpl().ChannelOpenInit(0, cur, msg)
}

func ChannelOpenTry(cur realm, msg types.MsgChannelOpenTry) {
	access.AssertCanCall(0, cur, SelectorChannelOpenTry)
	mustGetImpl().ChannelOpenTry(0, cur, msg)
}

func ForceChannelOpenTry(cur realm, msg types.MsgChannelOpenTry) {
	access.AssertCanCall(0, cur, SelectorForceChannelTry)
	mustGetImpl().ForceChannelOpenTry(0, cur, msg)
}

func ChannelOpenAck(cur realm, msg types.MsgChannelOpenAck) {
	access.AssertCanCall(0, cur, SelectorChannelOpenAck)
	mustGetImpl().ChannelOpenAck(0, cur, msg)
}

func ForceChannelOpenAck(cur realm, msg types.MsgChannelOpenAck) {
	access.AssertCanCall(0, cur, SelectorForceChannelAck)
	mustGetImpl().ForceChannelOpenAck(0, cur, msg)
}

func ChannelOpenConfirm(cur realm, msg types.MsgChannelOpenConfirm) {
	access.AssertCanCall(0, cur, SelectorChannelOpenConfirm)
	mustGetImpl().ChannelOpenConfirm(0, cur, msg)
}

func ForceChannelOpenConfirm(cur realm, msg types.MsgChannelOpenConfirm) {
	access.AssertCanCall(0, cur, SelectorForceChannelConfirm)
	mustGetImpl().ForceChannelOpenConfirm(0, cur, msg)
}

func ChannelCloseInit(cur realm, msg types.MsgChannelCloseInit) {
	access.AssertCanCall(0, cur, SelectorChannelCloseInit)
	mustGetImpl().ChannelCloseInit(0, cur, msg)
}

func ChannelCloseConfirm(cur realm, msg types.MsgChannelCloseConfirm) {
	access.AssertCanCall(0, cur, SelectorChannelCloseConfirm)
	mustGetImpl().ChannelCloseConfirm(0, cur, msg)
}
