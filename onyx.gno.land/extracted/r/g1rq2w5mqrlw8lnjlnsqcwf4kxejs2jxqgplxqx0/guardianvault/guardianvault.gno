package guardianvault

// VaultState 是金库的状态机。v1 只有两态，刻意保持单线：
//
//	ACTIVE ──RequestRecovery──▶ RECOVERING ──Execute──▶ ACTIVE（归属已转移）
//	   ▲                             │
//	   └──────CancelRecovery─────────┘
//
// 没有 PAUSED / FROZEN / DISPUTED。每多一态，就要多定义「谁能从这一态
// 走到哪一态」，而本项目的目标是把一条路径做对，不是把状态图铺满。
type VaultState int

const (
	ACTIVE VaultState = iota
	RECOVERING
)

// 参数边界。三条都是「不设就会静默失效」的类型，而不是锦上添花：
//
//   - WindowSecs 若允许 0，时间锁整层消失，否决权退化为与守护人抢速度；
//   - Guardians 若允许重复地址，threshold 可能高于去重后人数，
//     恢复在数学上永远不可达 —— 一次永久且无声的死锁；
//   - MaxGuardians 防的是「名单长到没法逐个核对」这种可用性陷阱。
const (
	MinWindowSecs = int64(3600)    // 1 小时
	MaxWindowSecs = int64(2592000) // 30 天
	MaxGuardians  = 10
)

// Vault 是一个金库的全部状态。
//
// 余额用内部 int64 记账，而不是持有 token 句柄或去问 banker —— 这不是
// 风格选择，而是唯一正确做法：同一 realm 下的所有 vault 共用一个 realm
// 地址，banker.GetCoin(realmAddr) 拿到的是合计值，无法区分单个 vault。
//
// 本类型在 /r/ 中声明，任何对外边界都不得以指针形式返回它。
type Vault struct {
	ID         int
	Owner      address
	BackupAddr address
	Guardians  []address
	Threshold  int
	WindowSecs int64
	Balance    int64 // ugnot

	State       VaultState
	Requestor   address
	RequestedAt int64 // unix 秒，取自 time.Now().Unix()
	Votes       []address

	RecoveryCount   int
	LastRecoveredAt int64
}

// vaults 是唯一的状态容器。未导出，外部只能经函数访问。
//
// ID == 索引，且只增不删（Execute 是重置不是删除），所以 vaults[id]
// 恒成立，mustGet 只需一次边界检查。省掉一张 map，也省掉「map 与 slice
// 不一致」这类状态 bug。
var vaults []*Vault

// mustGet 按 ID 取金库，越界即 panic。
func mustGet(id int) *Vault {
	if id < 0 || id >= len(vaults) {
		panic("no such vault")
	}
	return vaults[id]
}

// requireOwner 断言调用者是 owner。
// 身份只从 cur.Previous() 派生，从不接受地址参数。
func requireOwner(cur realm, v *Vault) {
	if cur.Previous().Address() != v.Owner {
		panic("caller is not the owner")
	}
}

// isGuardian 报告 addr 是否在该金库的守护人名单内。
func (v *Vault) isGuardian(addr address) bool {
	for _, g := range v.Guardians {
		if g == addr {
			return true
		}
	}
	return false
}

// hasVoted 报告 addr 是否已投过票。
// 投票按地址去重，因此名单里若出现重复地址，threshold 可能永不可达 ——
// 这正是 validateGuardians 必须去重的原因。
func (v *Vault) hasVoted(addr address) bool {
	for _, a := range v.Votes {
		if a == addr {
			return true
		}
	}
	return false
}

// validateGuardians 校验守护人名单与阈值。
//
// 阈值是调用方给的自由参数，只约束「凑得满」，不按人数推导公式：多数派 /
// 2/3 / n-1 在 n=3 上都是 2，公式在最常用的配置上没有任何收益，却在 n=2 时
// 要求全票（一人失联即死锁）、n=5 时要求 4 票（形同不可用）。取舍理由见
// README §3 与 OPEN-QUESTIONS D8。这里只守两条硬线：区间合法、名单去重。
//
// 去重是这里最要紧的一条：投票按地址去重（hasVoted），若名单含重复地址
// 且 threshold 高于去重后人数，恢复将永远凑不满票 —— 金库永久死锁，
// 且创建时不会有任何报错，只有真出事那天才暴露。
func validateGuardians(guardians []address, threshold int) {
	n := len(guardians)
	if n < 1 || n > MaxGuardians {
		panic("guardian count must be 1..10")
	}
	if threshold < 1 || threshold > n {
		panic("threshold must be within 1..len(guardians)")
	}
	for i := 0; i < n; i++ {
		if guardians[i] == address("") {
			panic("guardian must not be zero address")
		}
		for j := i + 1; j < n; j++ {
			if guardians[i] == guardians[j] {
				panic("duplicate guardian address")
			}
		}
	}
}

// validateWindow 校验恢复窗口长度。
// 下限 1 小时、上限 30 天：0 会让时间锁整体失效，过长则守护人自己也记不住。
func validateWindow(windowSecs int64) {
	if windowSecs < MinWindowSecs || windowSecs > MaxWindowSecs {
		panic("windowSecs must be within 3600..2592000")
	}
}
