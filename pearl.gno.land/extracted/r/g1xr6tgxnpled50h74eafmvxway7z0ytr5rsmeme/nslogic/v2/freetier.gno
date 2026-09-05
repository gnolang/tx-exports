package nslogic

import (
	"strconv"
	"time"

	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

/*
THE FREE TIER: a name somebody can hold without ever owning a wallet.

The vault has supported this since it was written — RegisterNameRecord
takes mintNFT=false and stores a record with no GRC-721 token, and
PromoteToNFTRecord is described there as "the paid free-tier upgrade".
Nothing in the logic realm ever reached either. This is that wiring.

WHY A RECORD WITHOUT A TOKEN IS THE RIGHT SHAPE, and not a compromise:

	IT IS A REAL NAME. Owned, resolvable, renewable, on chain, visible
	to anyone. Not a promise, not a queue position, not a row in our
	database. Everything the paid tier does except be sold.

	IT CANNOT BE SOLD, and that is what makes giving it away safe.
	nsmarket escrows a TOKEN, and there is no token — so a squatter who
	farms a thousand of these has farmed a thousand things nobody can
	buy from them. The anti-abuse property falls out of the data model
	rather than out of a rule somebody has to enforce.

	IT BECOMES SELLABLE BY BECOMING PAID. UpgradeFreeName takes the full
	list price and mints the token. So the same name costs nothing and
	costs full price, and which one depends entirely on whether you want
	to sell it.

WHY THE PROJECT PAYS. The whole point is somebody with no GNOT, and
possibly no wallet, who is going to put this name in front of an
audience. Measured on Pearl: a registration is about 0.04 GNOT of fee
plus a small storage deposit, and a free-tier record is smaller than a
paid one because there is no token and no ledger entry. That is a
marketing cost per name, bounded by a daily cap we apply off chain,
where it can be changed without a deploy.

WHAT IS DELIBERATELY NOT HERE. No wordlist: storage is 100 ugnot a byte,
so a ten-thousand-word dictionary is about 57 GNOT paid forever to
encode a marketing decision that will change. The contract carries the
structural rules in reserved.gno and nothing else; the lists live off
chain with the issuer, which is us, because the free path is granted
rather than bought. See tools/gen-reserved.py.
*/

const (
	keyFreeDomain = "free"      // per-domain: "1" means the free tier is open here
	keyGrantEnd   = "grantend"  // global: unix seconds, or "never"
	keyGranter    = "granter"   // global: the address allowed to issue grants
)

/*
THE GRANTER IS NOT THE ADMIN, and that separation is the point.

Free names are issued by a machine — something has to sign the grant
after a person proves an X account, and that key has to sit somewhere
warm. If that key were the admin key, a compromise of the issuing
machine would be a compromise of the registry: DeleteDomain destroys
every name under a domain and burns their tokens, instantly, with no
timelock.

So there is a second role that can do exactly one thing. Worst case for
a stolen granter key is that somebody gives away free names until we
notice and clear the role — a bounded, reversible, embarrassing loss
rather than an unbounded one.

Stored in the vault's globals rather than in this realm, so it survives
a logic redeploy. Unset means nobody but the admin may grant, which is
the right default for a role that exists to be delegated deliberately.
*/
func Granter() address {
	return address(nsdata.GetGlobal(keyGranter))
}

// SetGranter delegates grant issuance, or withdraws it. Passing the
// empty address is the revocation, and it is the first thing to reach
// for if the issuing machine is ever in doubt.
func SetGranter(cur realm, a address) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if a != "" && !a.IsValid() {
		panic("nslogic: not an address")
	}
	setGlobal(cur, keyGranter, a.String())
}

/*
SetFreeLengths tunes which lengths the free tier will issue.

In the panel rather than in a redeploy: nslogic is about 22 GNOT to
deploy, and "should four-character names be free this month" is a
marketing question that should cost a signature, not a deployment.

IT DOES NOT REACH BACKWARDS. Raising the minimum stops NEW issuance of
short names; every one already granted stays granted and keeps renewing
free. FreeLabelAllowed is called by GrantFreeName and by nothing else,
which is what makes that true — see the note on it in reserved.gno.
*/
func SetFreeLengths(cur realm, min, max int) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if min < 1 || max > 63 || min > max {
		panic("nslogic: a free-tier length range must sit inside 1..63 and be the right way round")
	}
	setGlobal(cur, keyFreeMin, strconv.Itoa(min))
	setGlobal(cur, keyFreeMax, strconv.Itoa(max))
}

func assertMayGrant(cur realm) {
	caller := cur.Previous().Address()
	if caller == nsdata.GetAdmin() {
		return
	}
	g := Granter()
	if g == "" || caller != g {
		panic("nslogic: only the admin or the granter may issue free names")
	}
}

// DomainFree reports whether a domain accepts free-tier registrations.
// Off by default, and per-domain on purpose: the free tier is a
// promotion aimed at a few domains, not a property of the registry.
func DomainFree(domainLabel string) bool {
	return nsdata.GetDomainExtra(domainLabel, keyFreeDomain) == "1"
}

// SetDomainFree opens or closes the free tier for one domain.
func SetDomainFree(cur realm, domainLabel string, on bool) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if !nsdata.DomainExists(domainLabel) {
		panic("nslogic: no such domain")
	}
	v := ""
	if on {
		v = "1"
	}
	if err := nsdata.SetDomainExtraRecord(cross(cur), domainLabel, keyFreeDomain, v); err != nil {
		panic(err)
	}
}

/*
GrantWindowOpen reports whether free grants are being issued at all.

A single global switch that closes everything at once, because the
failure this guards against is not a clever attack — it is noticing on a
Sunday that something is wrong and wanting one call that stops it. An
unset value means open; "never" means open with no end date, which is
what the admin panel already writes.
*/
func GrantWindowOpen() bool {
	return readGrantWindow(nsdata.GetGlobal(keyGrantEnd), time.Now().Unix())
}

// readGrantWindow is GrantWindowOpen with the clock and the stored value
// handed in, so the reading can be tested without a chain.
func readGrantWindow(v string, now int64) bool {
	if v == "" || v == "never" {
		return true
	}
	end, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		// An unparseable window is a misconfiguration, and the safe
		// reading of a misconfigured gate is "closed". Giving names away
		// because a setting was mistyped is the wrong way to fail.
		return false
	}
	return now < end
}

/*
GrantFreeName registers a free-tier record to somebody else.

ADMIN OR GRANTER, and that is the whole trust model: the eligibility rules —
which Twitter account, how old, how many followers, whether the label is
a dictionary word — live off chain with the issuer. Putting them here
would freeze a marketing policy into a realm and cost storage to do it.
What the chain enforces is the part that must not depend on our
correctness: the label is structurally allowed, the domain opted in, and
the window is open.

`owner` may be an address the recipient generated in their browser
seconds ago and has never funded. That is the point.
*/
func GrantFreeName(cur realm, label, domainLabel string, owner address) {
	assertNoSend(cur)
	assertMayGrant(cur)

	if !GrantWindowOpen() {
		panic("nslogic: free grants are closed")
	}
	if !DomainFree(domainLabel) {
		panic("nslogic: *" + domainLabel + " does not offer free names")
	}
	if !DomainOpen(domainLabel) {
		panic("nslogic: this domain is not accepting new names")
	}
	validateLabel(label)
	// The structural backstop. The issuer has already applied the full
	// policy; this is what stops a bug there giving away a four-letter
	// name or a pure-numeric one.
	if !FreeLabelAllowed(label) {
		panic("nslogic: " + label + " is not available on the free tier")
	}
	if !owner.IsValid() {
		panic("nslogic: a grant needs a recipient")
	}

	// mintNFT=false — a record, not a token. See the note at the top.
	if err := nsdata.RegisterNameRecord(cross(cur), label, domainLabel, owner,
		time.Now().Unix(), false); err != nil {
		panic(err)
	}
}

/*
UpgradeFreeName mints the token for a free-tier record, at full price.

This is the only way a free name becomes sellable, and the price is the
ordinary list price with no referral discount — a discount is for
bringing somebody new, and this person is already here.

`newOwner` exists because the common case is somebody who has decided to
sell and, in the same moment, wants the name in a wallet they actually
control rather than the browser key they were given. The vault handles
that move inside PromoteToNFTRecord.

Callable by the record's current owner only. Anyone may PAY for
somebody else's upgrade in the sense that they can hand over the money,
but they cannot perform it — a stranger promoting your name into a token
and choosing where it lands is a theft with a receipt.
*/
func UpgradeFreeName(cur realm, label, domainLabel string, newOwner address) {
	caller := cur.Previous().Address()
	if nsdata.GetNameOwner(label, domainLabel) != caller {
		panic("nslogic: restricted to name owner")
	}
	if !nsdata.IsNameValid(label, domainLabel) {
		panic("nslogic: this name has expired")
	}
	if newOwner == "" {
		newOwner = caller
	}
	if !newOwner.IsValid() {
		panic("nslogic: invalid destination address")
	}

	// Full list price, resolved now rather than at grant time — the
	// name's worth is what it is worth today, and a free name held for a
	// year should not be upgradable at last year's rate.
	takePaymentSplit(cur, NamePrice(domainLabel, label), "", 0)

	if err := nsdata.PromoteToNFTRecord(cross(cur), label, domainLabel, newOwner); err != nil {
		panic(err)
	}
}

/*
GrantFreeRenewal extends a free-tier name at no charge.

THE DEAL IS THE DISPLAY, and it is checked off chain: the issuer signs
somebody in on X, reads their display name, and finds the name in it.
That single act proves both halves at once — that a real account still
exists, and that it is still carrying the name — which is why renewal is
one click a year rather than a form.

FREE-TIER RECORDS ONLY. A paid name renewed for nothing is revenue given
away by accident, and the two are told apart by whether a token was ever
minted. isNFT is the flag, and it is the vault's, not ours.

NO OWNERSHIP PROOF IS ASKED FOR, and that is deliberate rather than
missing. Renewing somebody else's name is a GIFT — it takes nothing,
moves nothing, and grants the caller no power over it. The only cost of
allowing it is ours, and the vault's renewal cap already bounds how far
any single name can be pushed. A proof requirement here would buy
nothing and would cost the one-click renewal that makes the deal work.

RenewNameRecord insists the caller is the owner, so the owner is looked
up and passed. That is not a bypass: this realm is the trusted logic,
and what it is asserting is exactly true — this renewal is on that
owner's behalf.
*/
func GrantFreeRenewal(cur realm, label, domainLabel string) {
	assertNoSend(cur)
	assertMayGrant(cur)

	if !nsdata.NameExists(label, domainLabel) {
		panic("nslogic: no such name")
	}
	owner, _, _, _, _, isNFT := nsdata.GetNameInfo(label, domainLabel)
	if isNFT {
		panic("nslogic: " + label + "*" + domainLabel +
			" is a paid name — free renewal is for free-tier records")
	}
	if RenewalsLeft(label, domainLabel) <= 0 {
		panic("nslogic: this name is already paid as far ahead as a name may run")
	}
	if err := nsdata.RenewNameRecord(cross(cur), label, domainLabel, owner,
		time.Now().Unix()); err != nil {
		panic(err)
	}
}

// IsFreeTier reports whether a name is a record without a token — the
// free tier. Exported because the site and the issuer both need to ask
// before offering a free renewal, and neither should infer it.
func IsFreeTier(label, domainLabel string) bool {
	if !nsdata.NameExists(label, domainLabel) {
		return false
	}
	_, _, _, _, _, isNFT := nsdata.GetNameInfo(label, domainLabel)
	return !isNFT
}
