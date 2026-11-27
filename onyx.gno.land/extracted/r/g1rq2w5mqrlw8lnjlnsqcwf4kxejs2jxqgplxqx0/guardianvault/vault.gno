package guardianvault

import "time"

// 本文件是全部对外 crossing 函数，也是唯一的鉴权点。
//
// 三条贯穿始终的规矩：
//   - 每个函数第一行都是 cur.IsCurrent()，挡「伪装成本 realm 的中间层」；
//   - 身份只从 cur.Previous().Address() 派生，没有任何函数接受地址参数来
//     识别调用者 —— 地址只作为数据出现；
//   - 校验全部前置，任何一条不满足都在写状态之前 panic，不留半成品。
//
// 共 10 个函数，按职责分四组：
//   - 创建：CreateVault
//   - 资金：Deposit / Withdraw
//   - 配置：AddGuardian / SetGuardians / SetBackup
//   - 恢复：RequestRecovery / Vote / CancelRecovery / Execute

// CreateVault 创建一个新金库，调用者成为 owner，返回金库 ID。
//
// 参数校验全部前置：任何一条不满足都不留下半成品状态。
// 校验项与 README §3 的接口表逐条对应，没有「顺手多校验」也没有遗漏。
//
// guardians 是变参且必须放在最后，这不是风格选择，是链上调用机制的硬约束：
// MsgCall 的参数转换只支持原生类型与 []byte，`[]address` 会直接 panic
// （unexpected slice type in contract arg），用户用 gnokey / gnoweb 都调不动。
// 改用变参后，重复传入的 `-args` 正好对应变参列表，实测可用。
// 详见 OPEN-QUESTIONS F12 / F13。
func CreateVault(cur realm, threshold int, backup address, windowSecs int64, guardians ...address) int {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}

	owner := cur.Previous().Address()
	if owner == address("") {
		panic("owner must not be zero address")
	}
	validateGuardians(guardians, threshold)
	if backup == address("") {
		panic("backup address must not be zero")
	}
	validateWindow(windowSecs)

	// 复制入参 slice。调用方仍持有底层数组，若直接存引用，
	// 它可以在创建后改动名单，绕过「守护人名单变更需走 SetGuardians」。
	g := make([]address, len(guardians))
	copy(g, guardians)

	id := len(vaults)
	vaults = append(vaults, &Vault{
		ID:         id,
		Owner:      owner,
		BackupAddr: backup,
		Guardians:  g,
		Threshold:  threshold,
		WindowSecs: windowSecs,
		State:      ACTIVE,
	})
	return id
}

// Deposit 把本次交易附带的 ugnot 记入金库。
//
// 金额不是参数，只取自交易信封 —— 这样「存多少」由链上实际转账决定，
// 不存在「声称存了 100 实际转了 0」的空间。
func Deposit(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	amt := receivedUgnot(cur)
	if amt <= 0 {
		panic("no ugnot sent")
	}
	v.Balance += amt
}

// Withdraw 由 owner 取回 ugnot。
//
// 这是 D1 补上的出口：没有它，一个金库只能在「假装丢私钥、走一遍恢复」
// 之后才能取出钱，那不叫钱包。
//
// 恢复期间（RECOVERING）禁止取款：否则 owner 可以在守护人已经投满票之后
// 把余额转空，让 Execute 变成一次空转 —— 投票结果就必须被执行，不能因为
// 主人临时改主意而作废。
func Withdraw(cur realm, id int, to address, amount int64) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if to == address("") {
		panic("recipient must not be zero address")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	if amount > v.Balance {
		panic("insufficient balance")
	}

	// 先记账再转账。payUgnot 若 panic，整笔交易回滚，不会留下「钱出去了、
	// 账没减」的中间态；反过来写则多一个失败窗口。
	v.Balance -= amount
	payUgnot(cur, to, amount)
}

// AddGuardian 往名单末尾追加一个守护人，阈值不变。
//
// 为什么值得单独一条入口：建库时就把所有守护人凑齐，在现实中很难 ——
// 家人、朋友、同事的地址往往要陆续才拿得到，而 SetGuardians 要求一次性
// 交齐整份名单，中途加一个人就得把全部地址重新抄一遍，抄错一个就是一次
// 永久性配置错误。追加是高频操作，值得最省的那条路径。
//
// 为什么这条捷径不违反「阈值必须与名单共同提交」：追加只会让 N 变大、
// M 原地不动，因此 threshold <= N 依然成立 —— 它只会让「凑得满票」更
// 容易，绝不会更难。真正危险的方向是删除：把 N 减到低于 M 就是一次永久
// 死锁。所以删除与批量替换只走 SetGuardians（整体提交、整体校验），
// 增与减刻意不对称（OPEN-QUESTIONS D9）。
//
// 副作用提醒（已知且接受）：原本 M == N 的「全票」配置，加人之后会变成
// 「容错一人」。这是 owner 亲手点下这一笔的结果，不做二次确认 —— 链上
// 没有对话框，能做的只有把语义写清楚。
func AddGuardian(cur realm, id int, guardian address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if guardian == address("") {
		panic("guardian must not be zero address")
	}
	// 重复地址是这里唯一的死锁来源：投票按地址去重，名单里出现两个相同
	// 地址不会让票数变多，只会让 threshold 的可达性悄悄变差。
	if v.isGuardian(guardian) {
		panic("already a guardian")
	}
	if len(v.Guardians) >= MaxGuardians {
		panic("guardian count would exceed 10")
	}

	v.Guardians = append(v.Guardians, guardian)
}

// SetGuardians 整体替换守护人名单与阈值。
//
// 这是「批量 / 删除」的唯一入口：删除必须与新的阈值一起提交，否则
// threshold 可能高于剩余人数，恢复永远凑不满票。
func SetGuardians(cur realm, id int, threshold int, guardians ...address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	validateGuardians(guardians, threshold)

	g := make([]address, len(guardians))
	copy(g, guardians)
	v.Guardians = g
	v.Threshold = threshold
}

// SetBackup 替换备用地址。
//
// 允许改，是因为人可能换钱包、换设备；但恢复一旦开始就冻结 —— 否则
// 守护人可以在投票中途把目的地改到自己账上，第①层「目的地封闭」直接失效。
func SetBackup(cur realm, id int, backup address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if backup == address("") {
		panic("backup address must not be zero")
	}
	v.BackupAddr = backup
}

// RequestRecovery 开启恢复窗口，任何人可调。
//
// 为什么不是「仅守护人」：发现 owner 失联的第一个人未必是守护人，而发起
// 本身不产生任何权限增量 —— 它只把状态切到 RECOVERING、记下时间，真正
// 能改变归属的仍然是 M 票 + 窗口期满。多一道身份限制只会让流程更容易卡住。
//
// 发起者不会自动获得一票：投票是一条独立的、可审计的动作，藏在发起里会
// 让「谁真的投了票」变得含糊。
func RequestRecovery(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != ACTIVE {
		panic("vault is not active")
	}

	v.State = RECOVERING
	v.Requestor = cur.Previous().Address()
	v.RequestedAt = time.Now().Unix()
	v.Votes = nil
}

// Vote 由守护人投一票。
//
// 票数达到 threshold 后拒绝新票：让 Votes 恒 <= Threshold（不变量 I4），
// 也让「票够了」在界面上有确定含义，不会出现 5/3 这种读数。
func Vote(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}

	caller := cur.Previous().Address()
	if !v.isGuardian(caller) {
		panic("not a guardian")
	}
	if v.hasVoted(caller) {
		panic("already voted")
	}
	if len(v.Votes) >= v.Threshold {
		panic("enough votes already")
	}

	v.Votes = append(v.Votes, caller)
}

// CancelRecovery 由 owner 一票否决，回到 ACTIVE 并清空票数。
//
// 任何时刻可调、不需要理由：这是 owner 私钥还在手上时的唯一自保手段。
// 若给它加延迟或条件，等于把「抢跑」合法化。
func CancelRecovery(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}

	v.State = ACTIVE
	v.Votes = nil
	v.Requestor = address("")
	v.RequestedAt = 0
}

// Execute 把余额付给 BackupAddr，并把所有权移交给它。
//
// 任何人可调，且不产生权限增量：目的地已在注册时锁死，阈值与窗口已满足，
// owner 也已经放弃了否决。限定调用者只会让「已经投过票的守护人」再多发
// 一笔交易来收尾。
//
// 执行完不是回到原样，而是回到「未配置」的初始态：守护人清空、阈值归零。
// 旧 owner 的私钥已经不可用，这些守护人继续挂在这个金库上没有任何意义；
// 新 owner 若想再受保护，需要自己重新 AddGuardian / SetGuardians。
func Execute(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}
	if len(v.Votes) < v.Threshold {
		panic("threshold not reached")
	}

	now := time.Now().Unix()
	if now < v.RequestedAt+v.WindowSecs {
		panic("recovery window has not elapsed")
	}

	amt := v.Balance
	v.Balance = 0
	// 余额为零时不碰 banker：一笔 0 ugnot 的转账没有意义，而跨账户的零额
	// 转账在某些实现下会被拒绝，白搭一次失败。
	if amt > 0 {
		payUgnot(cur, v.BackupAddr, amt)
	}

	v.Owner = v.BackupAddr
	v.Guardians = nil
	v.Threshold = 0
	v.Votes = nil
	v.Requestor = address("")
	v.RequestedAt = 0
	v.State = ACTIVE

	v.RecoveryCount++
	v.LastRecoveredAt = now
}
