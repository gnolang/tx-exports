package idox

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	adminAddr     address
	policy        GuardrailPolicy
	vaultSeq      seqid.ID
	vaults        *avl.Tree // seqid string -> *ProjectVault
	profiles      *avl.Tree // address string -> *BuilderProfile
	auditLogs     []*AuditLog
	dailySpent    int64
	windowStartBk int64
)

func init(cur realm) {
	adminAddr = cur.Previous().Address()
	if adminAddr == "" {
		adminAddr = cur.Address()
	}
	windowStartBk = runtime.ChainHeight()

	vaults = avl.NewTree()
	profiles = avl.NewTree()

	policy = GuardrailPolicy{
		AgentAddr:         adminAddr,
		MaxSinglePayout:   50_000_000,  // 50 GNOT cap per milestone (in ugnot)
		DailySpendLimit:   150_000_000, // 150 GNOT rolling 24h cap
		CooldownBlocks:    10,          // Minimum blocks between AI approvals
		RequireBadgeMatch: true,
		Paused:            false,
	}
}

func SetGuardrailPolicy(cur realm, agent address, maxSingle int64, dailyLimit int64, cooldown int64, requireBadge bool, paused bool) {
	if cur.Previous().Address() != adminAddr {
		panic("unauthorized: admin only")
	}
	policy = GuardrailPolicy{
		AgentAddr:         agent,
		MaxSinglePayout:   maxSingle,
		DailySpendLimit:   dailyLimit,
		CooldownBlocks:    cooldown,
		RequireBadgeMatch: requireBadge,
		Paused:            paused,
	}
}

func Admin() address {
	return adminAddr
}

func GetVaultReleased(projectID uint64) int64 {
	return getVault(projectID).ReleasedAmount
}

func getOrCreateProfile(addr address, handle string) *BuilderProfile {
	key := addr.String()
	if raw := profiles.Get(key); raw != nil {
		return raw.(*BuilderProfile)
	}
	p := &BuilderProfile{
		Addr:   addr,
		Handle: handle,
		Badges: avl.NewTree(),
	}
	profiles.Set(key, p)
	return p
}

func getVault(projectID uint64) *ProjectVault {
	key := seqid.ID(projectID).String()
	raw := vaults.Get(key)
	if raw == nil {
		panic("project vault not found")
	}
	return raw.(*ProjectVault)
}
