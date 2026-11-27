package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// receivedUgnot 读取「本次交易实际付给本 realm」的 ugnot 数量。
//
// 守卫只需一条，但选哪一条是经过实测比较的，不是随手取一个：
//
//	cur.Previous().IsUserCall() —— 要求上一跳是纯 EOA（PkgPath == ""）。
//
// 它挡住两类攻击：
//   - 中间 realm 代为转发：信封可能已被中间层消费，而本 realm 仍看到原金额；
//   - MsgRun 的临时 realm（PkgPath = <domain>/e/<addr>/run，非空）。
//
// 为什么不用 IsUser()：它同时接受上述临时 realm，正是要挡的载体之一。
//
// 为什么不用 runtime.AssertOriginCall()：它确实更强，还能挡住
// `var X = other.Deposit` 这类「消息的币记给 A、执行的代码属于 B」的
// 别名转发。但它在单元测试里与 cur.Previous() 互斥 —— AssertOriginCall
// 要求调用方是直接 MsgCall（测试里等价于非 cross 调用），而
// cur.Previous() 在非 cross 调用下会因 prev 为 truly-nil 而 panic。
// 二者不可兼得，而身份正确性（owner 归属）是本项目的承重设计，必须可测。
// 别名转发的前提是 realm 自身存在 `var X = other.Y` 的写法，本项目没有。
// 完整实测记录见 OPEN-QUESTIONS F16。
//
// 本文件是全项目唯一 import chain/runtime/unsafe 的地方。unsafe 在这里
// 只用于读信封金额，绝不用于派生身份 —— 身份一律来自 cur。
func receivedUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("payment must come from a direct EOA call")
	}
	return unsafe.OriginSend().AmountOf("ugnot")
}

// payUgnot 从本 realm 的地址转出 ugnot。
//
// 红线：banker 即用即弃。BankerTypeRealmSend 是对 realm 地址的**永久**
// 花钱授权，没有过期、没有撤销、也不重新检查活性。一旦把它存进状态、
// 当作参数传出、或作为返回值交给调用方，等于把 realm 地址上**所有**
// 金库的钱一次性交出去 —— 所有 vault 共用同一个 realm 地址。
//
// 因此：只在函数局部创建，只在本函数内使用，用完即弃。
func payUgnot(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
