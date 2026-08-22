package nsdata

import "time"

// isValidNow / isReclaimable are pure time math over `termLength` and
// `gracePeriod`, both of which are settable — so the lifecycle rules
// themselves can be retuned after deployment.
func isValidNow(expires time.Time, now time.Time) bool {
	return now.Before(expires)
}

func isReclaimable(expires time.Time, now time.Time) bool {
	return !now.Before(expires.Add(gracePeriod))
}

// assertIsTrustedLogic is the gate on every mutation function below.
// cur.Previous().Address() resolves to the CALLING realm's own address
// when invoked via cross(cur) from another realm — same idiom already
// used for assertIsAdmin, just checking a different address. A stray
// call from anywhere else (a different realm, a direct user tx trying
// to call these directly) is rejected.
func assertIsTrustedLogic(cur realm) {
	// The pause check lives here rather than in each mutation so it can
	// never be forgotten on a new one: every write in the realm passes
	// through this gate.
	if paused {
		panic("nsdata: registry is paused")
	}
	if trustedLogicSet.Get(cur.Previous().Address().String()) == nil {
		panic("nsdata: restricted to a trusted logic realm")
	}
}

// -- key encodings --
//
// Two DIFFERENT orderings, deliberately, and it matters which is which:
//
//   storage key : domain + "*" + label   (nameTreeKey)
//   token ID    : label  + "*" + domain  (nameTokenID)
//
// The storage key is DOMAIN-first so that every per-domain query is a
// RANGED scan over a contiguous key span instead of a full-tree scan
// with a filter. Before this, ListNames/CountNames walked every name in
// the registry to answer a question about one domain, which made the
// gnoweb home page O(domains × names) — a permanent, unfixable DoS in an
// immutable realm once the registry grew. Since this realm is deployed
// exactly once, the key layout is a forever decision; it is made here.
//
// The token ID stays label-first because that is the user-facing
// identity (`alice*meme`), it is what the NFT exposes to every external
// tool, and it is what `primary` stores for reverse resolution.
//
// Neither a label nor a domain may contain "*" (enforced by
// validateLabel in the logic realm), so both encodings split
// unambiguously on the first "*".

func nameTreeKey(label, domain string) string { return domain + "*" + label }

func nameTokenID(label, domain string) string { return label + "*" + domain }

func domainTokenID(domain string) string { return "*" + domain }

// domainRange returns the [start, end) key bounds covering exactly the
// names stored under `domain`. '+' (0x2B) is the next byte after '*'
// (0x2A), so `domain+"+"` sorts immediately past every `domain+"*"+...`
// key while still sorting before any longer domain (e.g. "meme+" falls
// between "meme*zzz" and "memes*a").
func domainRange(domain string) (start, end string) {
	return domain + "*", domain + "+"
}

// splitTokenID splits a `label*domain` TOKEN ID. Do not use it on a
// storage key — see the ordering note above.
func splitTokenID(tid string) (label, domain string) {
	for i := 0; i < len(tid); i++ {
		if tid[i] == '*' {
			return tid[:i], tid[i+1:]
		}
	}
	return tid, ""
}

// -- lookups --

func mustGetDomain(label string) *Domain {
	v := domains.Get(label)
	if v == nil {
		panic("nsdata: unknown domain: " + label)
	}
	return v.(*Domain)
}

func getDomain(label string) (*Domain, bool) {
	v := domains.Get(label)
	if v == nil {
		return nil, false
	}
	return v.(*Domain), true
}

func mustGetName(label, domain string) *Name {
	v := names.Get(nameTreeKey(label, domain))
	if v == nil {
		panic("nsdata: unknown name: " + nameTokenID(label, domain))
	}
	return v.(*Name)
}

func getName(label, domain string) (*Name, bool) {
	v := names.Get(nameTreeKey(label, domain))
	if v == nil {
		return nil, false
	}
	return v.(*Name), true
}

// clearPrimaryIfPointingAt drops `owner`'s reverse-resolution pointer
// when (and only when) it still points at `tid`. Called on every
// ownership change — transfer and reclaim.
//
// Without this, `primary` was a write-only tree: it had a Set path and
// no Remove path anywhere in the realm, so selling or losing a name left
// the previous holder permanently reverse-resolving to a name somebody
// else now owns. Reverse resolution asserting ownership that is no
// longer true is the one thing a name service must never do.
func clearPrimaryIfPointingAt(owner address, tid string) {
	k := owner.String()
	if v := primary.Get(k); v != nil && v.(string) == tid {
		primary.Remove(k)
	}
}
