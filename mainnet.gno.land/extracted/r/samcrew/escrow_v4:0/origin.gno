package escrow_v4

// The only chain/runtime/unsafe uses in this realm. Nothing here reads a
// caller from the stack and no crossing entrypoint is declared in this file:
// entrypoints authenticate with cur.IsCurrent() and cur.Previous(), and
// requireExactSend only checks the kind of the frame-verified caller it is
// handed.

import (
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"
)

// publisherAtLoad captures the AddPackage signer during package
// initialization; it seeds admin and the fallback fee recipient.
func publisherAtLoad() address { return unsafe.OriginCaller() }

// requireExactSend panics unless caller (the entrypoint's cur.Previous()) is
// a direct user call and the transaction's send envelope holds exactly amount
// ugnot and no other denom. Only for a direct user call is the envelope
// credited to this realm, the message target; any other denom would be
// stranded here. The guard sits in this function, before the read, so the
// deployer's per-function fund-safety scan (lib/deploy.sh) sees it.
func requireExactSend(amount int64, caller realm) {
	if !caller.IsUserCall() {
		panic("FundMilestone must be a direct user call")
	}
	sent := int64(0)
	for _, coin := range unsafe.OriginSend() {
		if coin.Denom != "ugnot" {
			panic("only ugnot is accepted, got " + coin.Denom)
		}
		sent += coin.Amount
	}
	if sent != amount {
		panic(ufmt.Sprintf("must send exactly %d ugnot (sent %d)", amount, sent))
	}
}

// realmAddress is this realm's own address, for the NF-2 solvency getter.
func realmAddress() address { return unsafe.CurrentRealm().Address() }
