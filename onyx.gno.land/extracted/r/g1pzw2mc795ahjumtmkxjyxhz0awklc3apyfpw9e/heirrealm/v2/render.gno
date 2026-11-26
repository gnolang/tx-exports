package heirrealm

import (
	"strconv"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// Render is the gnoweb homepage for the realm. It lists every vault
// with its owner, beneficiary, balance, deadline and status, plus a
// short how-to. A single vault can be viewed at /<id>.
func Render(path string) string {
	if path != "" {
		id, err := strconv.Atoi(path)
		if err != nil {
			return "# HeirRealm\n\nUnknown vault."
		}
		v := vaults.Get(strconv.Itoa(id))
		if v == nil {
			return "# HeirRealm\n\nUnknown vault."
		}
		return renderVault(v.(*Vault))
	}
	out := "# HeirRealm — dead-man's switch for Gno\n\n"
	out += "Name a beneficiary and a check-in window. Check in before the window ends and nothing happens. "
	out += "Miss the window and any keeper can trigger the release: the beneficiary gets 98%, the keeper earns a 2% fee. "
	out += "No custodian, no will, no trusted third party.\n\n"
	out += "## Vaults\n\n"
	if nextVault == 0 {
		out += "No vaults yet. Create one with `CreateVault(beneficiary, intervalSeconds)` and attach ugnot with `-send`.\n"
		return out
	}
	for i := 1; i <= nextVault; i++ {
		v := vaults.Get(strconv.Itoa(i))
		if v == nil {
			continue
		}
		vv := v.(*Vault)
		out += ufmt.Sprintf("- Vault #%d — %s — balance %d ugnot — deadline %s\n",
			vv.ID, vv.Status(), vv.Balance, vv.Deadline.Format(time.RFC3339))
	}
	out += "\n## How it works\n\n"
	out += "1. `CreateVault(beneficiary, intervalSeconds)` + `-send` ugnot — you are the owner.\n"
	out += "2. `CheckIn(vaultID)` before the deadline to reset the timer.\n"
	out += "3. `Heartbeat(vaultID)` during the post-deadline grace period to revive the vault and reset the deadline (owner only).\n"
	out += "4. `Deposit(vaultID)` + `-send` ugnot to top up (owner only, timer unchanged).\n"
	out += "5. After deadline + grace period, anyone except the owner or beneficiary calls `TriggerRelease(vaultID)` and earns 2%.\n"
	out += "6. `Cancel(vaultID)` refunds the owner in full — owner only, before the deadline.\n"
	return out
}

func renderVault(v *Vault) string {
	out := ufmt.Sprintf("# HeirRealm — Vault #%d\n\n", v.ID)
	out += ufmt.Sprintf("- Status: %s\n", v.Status())
	out += ufmt.Sprintf("- Owner: %s\n", v.Owner)
	out += ufmt.Sprintf("- Beneficiary: %s\n", v.Beneficiary)
	out += ufmt.Sprintf("- Balance: %d ugnot\n", v.Balance)
	out += ufmt.Sprintf("- Check-in interval: %d seconds\n", v.Interval)
	out += ufmt.Sprintf("- Deadline: %s\n", v.Deadline.Format(time.RFC3339))
	out += ufmt.Sprintf("- Grace period ends: %s (%d seconds)\n", v.GraceEnd().Format(time.RFC3339), v.GracePeriod)
	out += ufmt.Sprintf("- Keeper fee at release: %d ugnot (2%%)\n", v.KeeperFee())
	out += ufmt.Sprintf("- Beneficiary share at release: %d ugnot (98%%)\n", v.BeneficiaryShare())
	if v.Released {
		out += ufmt.Sprintf("- Released by keeper: %s at %s\n", v.Keeper, v.ReleasedAt.Format(time.RFC3339))
	}
	return out
}
