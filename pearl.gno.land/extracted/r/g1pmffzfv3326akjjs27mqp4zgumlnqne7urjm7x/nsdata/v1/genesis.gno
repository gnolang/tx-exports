package nsdata

import "gno.land/p/nt/avl/v0"

/*
GENESIS — the state a registry is born with.

WHY IT LIVES IN THE PACKAGE. This project has been through three chains
(topaz-1, sapphire-1, pearl-1), and every time the price list, the
referral tiers and the domain list existed only as somebody's memory of an
afternoon spent in the admin panel. A value set by hand after deployment
is a value that is lost with the chain. A value in this file ships with
the realm.

WHY nsdata AND NOT nslogic. This realm owns the state it writes, so init
can write it with no permission from anybody. nslogic cannot: it writes
through this realm's trust gate, and trust is granted by a timelocked
proposal AFTER deployment — an init in nslogic would panic before the
grant existed and take the deploy down with it.

WHY DOMAINS CAN BE CREATED HERE AT ALL. They used to be tokens, and
minting one needs nsnft to trust this realm, which it cannot yet do during
init. Domains are records now (MIGRATION.md, rule 7), so creating one is a
tree write and nothing more.

WHAT IS NOT HERE. Names. No holder's records carry from one chain to the
next — that is the owner's decision (see the mainnet checklist): testnet
wallets get an entitlement, not their old records. And nothing that names
a generation — the token URI base, the lab domain — because this file is
meant to be the same for the sandbox and for mainnet.

EVERY VALUE IS VALIDATED AND A BAD ONE PANICS. A genesis file that quietly
skipped a malformed global would deploy a registry that looks configured
and is missing its price list, and nothing would say so until somebody was
charged the fallback. Failing the deploy costs one retry.

The data itself is generated into genesis_data.gno by
tools/freeze-genesis.py, from a snapshot of a chain that was configured by
hand. Edit the chain, snapshot it, regenerate; do not edit the data file.
*/

// Genesis domains get a long runway. They are project-owned and all
// created in the same block, so a single term would have every one of them
// lapse on the same day a year later — and a lapsed domain refuses every
// registration under it. Renewing them is still the admin's job; this
// just stops the first renewal being a cliff.
const genesisDomainTerms = 10

/*
refusedInGenesis names what may never be baked into a registry's birth.

Anything whose VALUE is an address: a key that holds power — the free-tier
granter was the one that shipped by accident — is set deliberately, after
deploy, on the chain it belongs to, never inherited from whatever chain a
snapshot was taken on. And the lab nomination, which belongs to a sandbox
generation and would otherwise let a hand-edited data file ship a lab on
a real domain.

No regexp: one compiled pattern costs more storage than this whole file.
*/
func refusedInGenesis(key, value string) bool {
	if key == "labdomain" || key == "granter" {
		return true
	}
	return looksLikeAddress(value)
}

func looksLikeAddress(v string) bool {
	if len(v) != 40 || v[0] != 'g' || v[1] != '1' {
		return false
	}
	for i := 2; i < len(v); i++ {
		c := v[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

type genesisCfg struct {
	termLength, gracePeriod                           int64
	minLabelLen, maxLabelLen                          int
	maxExtraKeyLen, maxExtraValueLen, maxExtraEntries int
	maxDeletePerCall                                  int
}

type genesisDomain struct {
	label string
	extra [][2]string
}

func applyGenesis(deployer address, now int64) {
	// Limits first, so every extra written below is held to them.
	c := genesisConfig()
	if c.maxExtraKeyLen > 0 {
		maxExtraKeyLen = c.maxExtraKeyLen
	}
	if c.maxExtraValueLen > 0 {
		maxExtraValueLen = c.maxExtraValueLen
	}
	if c.maxExtraEntries > 0 {
		maxExtraEntries = c.maxExtraEntries
	}
	if c.maxDeletePerCall > 0 {
		maxDeletePerCall = c.maxDeletePerCall
	}
	if c.minLabelLen > 0 {
		minLabelLen = c.minLabelLen
	}
	if c.maxLabelLen > 0 {
		maxLabelLen = c.maxLabelLen
	}
	if c.termLength > 0 {
		termLength = c.termLength
	}
	if c.gracePeriod > 0 {
		gracePeriod = c.gracePeriod
	}
	// The one invariant the lifecycle setters guard, guarded here too:
	// anchoring a renewal to its previous due date only makes sense while a
	// renewal cannot land more than one term late.
	if gracePeriod > termLength {
		panic("nsdata genesis: grace period is longer than the term")
	}

	for _, kv := range genesisGlobals() {
		for _, r := range reservedGlobals {
			if kv[0] == r {
				panic("nsdata genesis: " + r + " belongs to the restore machinery")
			}
		}
		if refusedInGenesis(kv[0], kv[1]) {
			panic("nsdata genesis: " + kv[0] + " holds an address or names a generation; set it after deploy, deliberately")
		}
		if err := setExtra(&globals, kv[0], kv[1]); err != nil {
			panic("nsdata genesis: global " + kv[0] + ": " + err.Error())
		}
	}

	for _, g := range genesisDomains() {
		if err := assertLabelKeySafe(g.label); err != nil {
			panic("nsdata genesis: domain " + g.label + ": " + err.Error())
		}
		if len(g.label) < minLabelLen || len(g.label) > maxLabelLen {
			panic("nsdata genesis: domain " + g.label + " is outside the label length limits")
		}
		if _, dup := getDomain(g.label); dup {
			panic("nsdata genesis: domain " + g.label + " is listed twice")
		}
		// Owned by the deployer, like every domain the admin registers.
		// Under `gno test` there is no deployer, and the domains are still
		// created so the tests exercise the same registry a chain gets.
		d := &Domain{owner: deployer, registered: now,
			expires: now + genesisDomainTerms*termLength, extra: avl.Tree{}}
		for _, kv := range g.extra {
			if err := setExtra(&d.extra, kv[0], kv[1]); err != nil {
				panic("nsdata genesis: domain " + g.label + " key " + kv[0] + ": " + err.Error())
			}
		}
		domains.Set(g.label, d)
	}
}
