package escrow_v3

import (
	"crypto/sha256"
	"encoding/hex"
	cfg "gno.land/r/samcrew/memba_market_config"
	"strconv"
)

// Value-only copies: no Contract pointer or persistent milestone slice escapes.
type GovernanceMilestone struct {
	ID                                int
	Amount                            int64
	Status                            string
	FundedAt, CompletedAt, DisputedAt int64
	PreDisputeStatus                  string
}
type GovernanceContract struct {
	Exists                  bool
	ID, ContentHash, Status string
	Client, Freelancer      address
	Count                   int
	Milestones              [20]GovernanceMilestone
}

func GetGovernanceContract(id string) GovernanceContract {
	v, ok := contracts.Get(id)
	if !ok {
		return GovernanceContract{}
	}
	c := v.(*Contract)
	if len(c.Milestones) > 20 {
		panic("invalid escrow milestone count")
	}
	s := GovernanceContract{Exists: true, ID: c.ID, Status: string(c.Status), Client: c.Client, Freelancer: c.Freelancer, Count: len(c.Milestones)}
	metadata := "escrow-metadata/v1" + escrowMetadataField(c.ID) + escrowMetadataField(string(c.Client)) + escrowMetadataField(string(c.Freelancer)) + escrowMetadataField(c.Title) + escrowMetadataField(c.Description) + escrowMetadataField(strconv.FormatInt(c.CreatedAt, 10)) + escrowMetadataField(strconv.Itoa(len(c.Milestones)))
	for i, m := range c.Milestones {
		s.Milestones[i] = GovernanceMilestone{ID: m.ID, Amount: m.Amount, Status: string(m.Status), FundedAt: m.FundedAt, CompletedAt: m.CompletedAt, DisputedAt: m.DisputedAt, PreDisputeStatus: string(m.PreDisputeStatus)}
		metadata += escrowMetadataField(strconv.Itoa(m.ID)) + escrowMetadataField(m.Title) + escrowMetadataField(strconv.FormatInt(m.Amount, 10))
	}
	digest := sha256.Sum256([]byte(metadata))
	s.ContentHash = hex.EncodeToString(digest[:])
	return s
}

type GovernanceFeeTerms struct {
	RawBPS, EffectiveBPS                             int64
	RawTreasury, FallbackTreasury, EffectiveTreasury address
}

func GetGovernanceFeeTerms() GovernanceFeeTerms {
	bps, treasury := resolveFee()
	return GovernanceFeeTerms{RawBPS: int64(cfg.GetFeeBPS(laneService)), EffectiveBPS: bps, RawTreasury: cfg.GetTreasury(), FallbackTreasury: feeFallback, EffectiveTreasury: treasury}
}

func escrowMetadataField(value string) string { return strconv.Itoa(len(value)) + ":" + value }
