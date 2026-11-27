package vault

import "strconv"

// Render 是 gnoweb 的入口。path 是 realm 之后的 URL 路径：
//
//	""     → 索引页，列出所有金库
//	"<id>" → 单个金库的详情页
//
// 界面直接由状态算出，没有前端、没有缓存、没有第二份真相。
func Render(path string) string {
	if path == "" {
		return renderIndex()
	}
	id, err := strconv.Atoi(path)
	if err != nil {
		return "# GuardianVault\n\nPath must be a vault ID, got `" + path + "`.\n"
	}
	return renderVault(id)
}

func renderIndex() string {
	out := "# GuardianVault\n\n"
	out += "A social-recovery vault: guardians can return your funds to the "
	out += "backup address you registered before losing your key — "
	out += "and can never send them anywhere else.\n\n"

	if len(vaults) == 0 {
		return out + "*No vaults yet.*\n"
	}

	out += "**Vaults:** " + strconv.Itoa(len(vaults)) + "\n\n"
	out += "| ID | Owner | Balance (ugnot) | State |\n"
	out += "| --- | --- | --- | --- |\n"
	for _, v := range vaults {
		out += "| [" + strconv.Itoa(v.ID) + "](" + strconv.Itoa(v.ID) + ") "
		out += "| `" + shortAddr(v.Owner) + "` "
		out += "| " + strconv.FormatInt(v.Balance, 10) + " "
		out += "| " + stateName(v.State) + " |\n"
	}
	return out
}

func renderVault(id int) string {
	if id < 0 || id >= len(vaults) {
		return "# Vault not found\n\nNo vault with ID " + strconv.Itoa(id) + ".\n"
	}
	v := vaults[id]

	out := "# Vault #" + strconv.Itoa(v.ID) + "\n\n"
	out += "| Field | Value |\n"
	out += "| --- | --- |\n"
	out += "| Owner | `" + v.Owner.String() + "` |\n"
	out += "| Backup address | `" + v.BackupAddr.String() + "` |\n"
	out += "| Balance | " + strconv.FormatInt(v.Balance, 10) + " ugnot |\n"
	out += "| State | " + stateName(v.State) + " |\n"
	out += "| Guardians | " + strconv.Itoa(len(v.Guardians)) + " |\n"
	out += "| Threshold | " + strconv.Itoa(v.Threshold) + " of " + strconv.Itoa(len(v.Guardians)) + " |\n"
	out += "| Recovery window | " + windowText(v.WindowSecs) + " |\n"
	out += "| Completed recoveries | " + strconv.Itoa(v.RecoveryCount) + " |\n"

	out += "\n## Guardians\n\n"
	for _, g := range v.Guardians {
		out += "- `" + g.String() + "`\n"
	}

	if v.State == RECOVERING {
		out += "\n## Recovery in progress\n\n"
		out += "| Field | Value |\n| --- | --- |\n"
		out += "| Requested by | `" + v.Requestor.String() + "` |\n"
		out += "| Votes | " + strconv.Itoa(len(v.Votes)) + " of " + strconv.Itoa(v.Threshold) + " required |\n"
	}

	return out
}

// stateName 把状态机取值转成可读文本。
func stateName(s VaultState) string {
	if s == ACTIVE {
		return "ACTIVE"
	}
	return "RECOVERING"
}

// windowText 把秒数转成可读时长。
//
// 不能简单地写 secs/3600 + " hours"：windowSecs 允许任意秒数（只限区间），
// 5400 秒会被截断显示成「1 hours」—— 界面上的数字与真实窗口不一致，
// 而恢复窗口正是用户判断「我还有多久能否决」的唯一依据。单数也不该写成
// 「1 hours」。
func windowText(secs int64) string {
	h := secs / 3600
	m := (secs % 3600) / 60
	s := secs % 60

	if m == 0 && s == 0 {
		if h == 1 {
			return "1 hour"
		}
		return strconv.FormatInt(h, 10) + " hours"
	}

	out := strconv.FormatInt(h, 10) + "h"
	if m > 0 {
		out += " " + strconv.FormatInt(m, 10) + "m"
	}
	if s > 0 {
		out += " " + strconv.FormatInt(s, 10) + "s"
	}
	return out
}

// shortAddr 把长地址压缩成 `g1abc…wxyz` 形式，用于表格列。
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}
