package sales

import (
	"strconv"
	"strings"

	"gno.land/p/samcrew/launchpad/merkle/v1"
	"gno.land/r/samcrew/launchpad/tokens/v1"
)

const maxFairHoldingGateBytes = 256
const maxFairProofBytes = merkle.MaxDepth*64 + merkle.MaxDepth - 1

type fairHoldingGate struct {
	TokenID string
	Minimum int64
}

// Gates are at most three canonical, strictly token-ID-ordered records:
// token:T<n>:<positive base units>. Collection gates remain unavailable until
// the collection realm and its BalanceOf interface are implemented.
func parseFairHoldingGates(spec string) []fairHoldingGate {
	if spec == "" {
		return nil
	}
	if len(spec) > maxFairHoldingGateBytes {
		panic("launchpad/sales: invalid fair holding gates")
	}
	parts := strings.Split(spec, ";")
	if len(parts) > 3 {
		panic("launchpad/sales: invalid fair holding gates")
	}
	gates := make([]fairHoldingGate, len(parts))
	previous := ""
	for i, part := range parts {
		fields := strings.Split(part, ":")
		if len(fields) != 3 || fields[0] != "token" || fields[1] == "" ||
			(previous != "" && fields[1] <= previous) {
			panic("launchpad/sales: invalid fair holding gates")
		}
		minimum, err := strconv.ParseInt(fields[2], 10, 64)
		if err != nil || minimum <= 0 || strconv.FormatInt(minimum, 10) != fields[2] {
			panic("launchpad/sales: invalid fair holding gates")
		}
		tokens.GetInfo(fields[1])
		gates[i] = fairHoldingGate{TokenID: fields[1], Minimum: minimum}
		previous = fields[1]
	}
	return gates
}

func validateFairEligibility(root, gates string) {
	if root != "" {
		h, err := merkle.ParseHash(root)
		if err != nil || merkle.FormatHash(h) != root || h == (merkle.Hash{}) {
			panic("launchpad/sales: invalid fair allowlist root")
		}
	}
	parseFairHoldingGates(gates)
}

// The leaf is sha256(0x00 || "launchpad-fair-v1|<token-id>|<buyer>").
// The token ID prevents a valid proof from being reused for a different sale.
func requireFairEligibility(id string, r FairSaleRecord, buyer address, proof string) {
	if r.AllowlistRoot == "" {
		if proof != "" {
			panic("launchpad/sales: fair proof not expected")
		}
	} else {
		if len(proof) > maxFairProofBytes {
			panic("launchpad/sales: invalid fair allowlist proof")
		}
		parsed, err := merkle.ParseProof(proof)
		if err != nil {
			panic("launchpad/sales: invalid fair allowlist proof")
		}
		if proof != "" {
			parts := strings.Split(proof, ",")
			for i, sibling := range parsed {
				if merkle.FormatHash(sibling) != parts[i] {
					panic("launchpad/sales: invalid fair allowlist proof")
				}
			}
		}
		root, _ := merkle.ParseHash(r.AllowlistRoot)
		leaf := merkle.Leaf([]byte("launchpad-fair-v1|" + id + "|" + buyer.String()))
		if !merkle.Verify(root, leaf, parsed) {
			panic("launchpad/sales: fair allowlist denied")
		}
	}
	for _, gate := range parseFairHoldingGates(r.HoldingGates) {
		if tokens.BalanceOf(gate.TokenID, buyer) < gate.Minimum {
			panic("launchpad/sales: fair holding gate denied")
		}
	}
}
