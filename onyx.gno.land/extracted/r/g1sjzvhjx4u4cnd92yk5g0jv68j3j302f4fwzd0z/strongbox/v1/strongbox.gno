// Package strongbox is a multisig team treasury for gno.land.
//
// A team creates a vault with a list of signers and a threshold (for
// example 2-of-3). Anyone can fund the vault with GNOT. Any signer can
// propose a payout; once enough signers approve, the payout is sent
// automatically. Everything is visible on the realm's gnoweb page.
//
// All vaults share the realm's bank account; each vault's share is tracked
// in Vault.Balance. Coins sent to the realm address without Deposit belong
// to no vault and cannot be paid out.
package strongbox

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	Denom      = "ugnot"
	MaxSigners = 20
	MaxNameLen = 64
	MaxMemoLen = 280
	// MaxOpenPerProposer caps the pending proposals one signer can have in
	// a vault, so a hostile signer cannot flood it.
	MaxOpenPerProposer = 20
)

type Status int

const (
	StatusPending Status = iota
	StatusExecuted
	StatusCancelled
)

func (s Status) String() string {
	switch s {
	case StatusPending:
		return "pending"
	case StatusExecuted:
		return "paid"
	case StatusCancelled:
		return "cancelled"
	}
	return "unknown"
}

type Proposal struct {
	ID        int
	Proposer  address
	To        address
	Amount    int64
	Memo      string
	Approvals []address
	Status    Status
	CreatedAt int64 // block height
	ClosedAt  int64 // block height, 0 while pending
}

type Inflow struct {
	From   address
	Amount int64
	Height int64
}

type Vault struct {
	ID        int
	Name      string
	Creator   address
	Signers   []address
	Threshold int
	Balance   int64
	// History lives in AVL trees, not slices: a call then touches a few
	// tree nodes instead of rewriting the whole history, so its cost stays
	// flat however long the vault is used. With slices, a hostile signer
	// could grow the history until no transaction fits in the gas limit,
	// locking the funds.
	Proposals     *avl.Tree // padded proposal id -> *Proposal
	ProposalCount int
	Pending       []int     // ids of pending proposals, oldest first (bounded)
	OpenBy        *avl.Tree // proposer address -> number of pending proposals
	PaidTotal     int64     // ugnot paid out so far
	Inflows       *avl.Tree // padded sequence -> Inflow
	InflowCount   int
	CreatedAt     int64
}

var (
	vaults      = avl.NewTree() // padded vault id -> *Vault
	bySigner    = avl.NewTree() // signer address + "/" + padded vault id -> true
	signerCount = avl.NewTree() // signer address -> number of vaults
	nextID      = 1
	pkgPath     string
)

func init(cur realm) {
	pkgPath = cur.PkgPath()
}

// ---------------------------------------------------------------------------
// Transactions

// CreateVault creates a vault. signers is a comma-separated list of
// addresses; the caller is always added as a signer. threshold is the
// number of approvals a payout needs. Returns the new vault id.
func CreateVault(cur realm, name string, signers string, threshold int) int {
	caller := cur.Previous().Address()
	assertNoCoins(cur)

	name = strings.TrimSpace(name)
	require(name != "", "name is required")
	require(len(name) <= MaxNameLen, "name is too long (max "+strconv.Itoa(MaxNameLen)+" bytes)")
	require(isCleanText(name), "name contains control or invisible characters")

	list := []address{caller}
	for _, raw := range strings.Split(signers, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		addr := normalize(address(raw))
		require(addr.IsValid(), "invalid signer address: "+raw)
		// The realm can never approve anything, so as a signer it would only
		// make the threshold harder or impossible to reach.
		require(addr != cur.Address(), "the Strongbox realm cannot be a signer")
		if !contains(list, addr) {
			list = append(list, addr)
		}
		require(len(list) <= MaxSigners, "too many signers (max "+strconv.Itoa(MaxSigners)+")")
	}
	require(threshold >= 1, "threshold must be at least 1")
	require(threshold <= len(list), "threshold ("+strconv.Itoa(threshold)+") is higher than the number of signers ("+strconv.Itoa(len(list))+")")

	id := nextID
	nextID++
	v := &Vault{
		ID:        id,
		Name:      name,
		Creator:   caller,
		Signers:   list,
		Threshold: threshold,
		Proposals: avl.NewTree(),
		OpenBy:    avl.NewTree(),
		Inflows:   avl.NewTree(),
		CreatedAt: runtime.ChainHeight(),
	}
	vaults.Set(key(id), v)
	for _, s := range list {
		bySigner.Set(s.String()+"/"+key(id), true)
		n, _ := signerCount.Get(s.String()).(int)
		signerCount.Set(s.String(), n+1)
	}

	chain.Emit("VaultCreated", "id", strconv.Itoa(id), "threshold", strconv.Itoa(threshold), "signers", strconv.Itoa(len(list)))
	return id
}

// Deposit adds the ugnot sent with this call to the vault. Anyone can
// deposit. It must be called directly (gnokey maketx call -send ...).
func Deposit(cur realm, vaultID int) {
	// Only a direct user call: a realm in between could otherwise call
	// Deposit several times and count the same sent coins more than once.
	require(cur.Previous().IsUserCall(), "Deposit must be called directly with gnokey maketx call -send")
	v := mustVault(vaultID)

	sent := unsafe.OriginSend()
	require(len(sent) > 0, "send ugnot with the call (-send 1000000ugnot)")
	for _, c := range sent {
		require(c.Denom == Denom, "only "+Denom+" can be deposited")
	}
	amount := sent.AmountOf(Denom)
	require(amount > 0, "deposit amount must be positive")

	v.Balance += amount
	v.InflowCount++
	v.Inflows.Set(key(v.InflowCount), Inflow{
		From:   cur.Previous().Address(),
		Amount: amount,
		Height: runtime.ChainHeight(),
	})
	chain.Emit("Deposit", "vault", strconv.Itoa(vaultID), "amount", strconv.FormatInt(amount, 10))
}

// Propose creates a payout proposal. Only signers can propose; the
// proposer's approval is counted. If the threshold is 1 and the vault has
// enough funds, the payout is sent at once. Returns the proposal id.
func Propose(cur realm, vaultID int, to address, amount int64, memo string) int {
	caller := cur.Previous().Address()
	assertNoCoins(cur)
	v := mustVault(vaultID)
	mustSigner(v, caller)

	to = normalize(to)
	require(to.IsValid(), "invalid recipient address")
	// Paying the realm itself would take coins out of the vault's balance
	// while leaving them in the realm, owned by no vault.
	require(to != cur.Address(), "cannot pay out to the Strongbox realm itself")
	require(amount > 0, "amount must be positive")
	memo = strings.TrimSpace(memo)
	require(len(memo) <= MaxMemoLen, "memo is too long (max "+strconv.Itoa(MaxMemoLen)+" bytes)")
	require(isCleanText(memo), "memo contains control or invisible characters")
	open, _ := v.OpenBy.Get(caller.String()).(int)
	require(open < MaxOpenPerProposer, "you already have "+strconv.Itoa(MaxOpenPerProposer)+" open proposals in this vault; cancel or finish some first")

	p := &Proposal{
		ID:        v.ProposalCount + 1,
		Proposer:  caller,
		To:        to,
		Amount:    amount,
		Memo:      memo,
		Approvals: []address{caller},
		Status:    StatusPending,
		CreatedAt: runtime.ChainHeight(),
	}
	v.ProposalCount++
	v.Proposals.Set(key(p.ID), p)
	v.Pending = append(v.Pending, p.ID)
	v.OpenBy.Set(caller.String(), open+1)
	chain.Emit("Proposed", "vault", strconv.Itoa(vaultID), "proposal", strconv.Itoa(p.ID), "amount", strconv.FormatInt(amount, 10))

	tryExecute(cur, v, p)
	return p.ID
}

// Approve adds the caller's approval. When the threshold is reached and
// the vault holds enough funds, the payout is sent in the same call.
func Approve(cur realm, vaultID int, proposalID int) {
	caller := cur.Previous().Address()
	assertNoCoins(cur)
	v := mustVault(vaultID)
	mustSigner(v, caller)
	p := mustPending(v, proposalID)
	require(!contains(p.Approvals, caller), "you already approved this proposal")

	p.Approvals = append(p.Approvals, caller)
	chain.Emit("Approved", "vault", strconv.Itoa(vaultID), "proposal", strconv.Itoa(proposalID), "approvals", strconv.Itoa(len(p.Approvals)))

	tryExecute(cur, v, p)
}

// Revoke withdraws the caller's approval of a pending proposal.
func Revoke(cur realm, vaultID int, proposalID int) {
	caller := cur.Previous().Address()
	assertNoCoins(cur)
	v := mustVault(vaultID)
	mustSigner(v, caller)
	p := mustPending(v, proposalID)

	idx := indexOf(p.Approvals, caller)
	require(idx >= 0, "you have not approved this proposal")
	kept := make([]address, 0, len(p.Approvals)-1)
	for i, a := range p.Approvals {
		if i != idx {
			kept = append(kept, a)
		}
	}
	p.Approvals = kept
	chain.Emit("Revoked", "vault", strconv.Itoa(vaultID), "proposal", strconv.Itoa(proposalID))
}

// Execute sends an approved payout that could not be sent earlier, for
// example because the vault was short of funds when the last approval
// came in. Any signer can call it.
func Execute(cur realm, vaultID int, proposalID int) {
	caller := cur.Previous().Address()
	assertNoCoins(cur)
	v := mustVault(vaultID)
	mustSigner(v, caller)
	p := mustPending(v, proposalID)

	require(len(p.Approvals) >= v.Threshold, "not enough approvals: "+strconv.Itoa(len(p.Approvals))+"/"+strconv.Itoa(v.Threshold))
	require(v.Balance >= p.Amount, "vault balance too low: has "+formatGNOT(v.Balance)+", needs "+formatGNOT(p.Amount))
	pay(cur, v, p)
}

// Cancel closes a pending proposal. Only its proposer can cancel it.
func Cancel(cur realm, vaultID int, proposalID int) {
	caller := cur.Previous().Address()
	assertNoCoins(cur)
	v := mustVault(vaultID)
	p := mustPending(v, proposalID)
	require(p.Proposer == caller, "only the proposer can cancel this proposal")

	p.Status = StatusCancelled
	p.ClosedAt = runtime.ChainHeight()
	closePending(v, p)
	chain.Emit("Cancelled", "vault", strconv.Itoa(vaultID), "proposal", strconv.Itoa(proposalID))
}

// ---------------------------------------------------------------------------
// Read-only helpers, for other realms and scripts

func VaultBalance(vaultID int) int64 { return mustVault(vaultID).Balance }

func VaultThreshold(vaultID int) int { return mustVault(vaultID).Threshold }

func IsSigner(vaultID int, addr address) bool {
	return contains(mustVault(vaultID).Signers, normalize(addr))
}

func VaultCount() int { return nextID - 1 }

// ---------------------------------------------------------------------------
// Internals

func tryExecute(cur realm, v *Vault, p *Proposal) {
	if len(p.Approvals) >= v.Threshold && v.Balance >= p.Amount {
		pay(cur, v, p)
	}
}

func pay(cur realm, v *Vault, p *Proposal) {
	// Update state before moving coins.
	v.Balance -= p.Amount
	v.PaidTotal += p.Amount
	p.Status = StatusExecuted
	p.ClosedAt = runtime.ChainHeight()
	closePending(v, p)

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), p.To, chain.Coins{{Denom, p.Amount}})
	chain.Emit("Paid", "vault", strconv.Itoa(v.ID), "proposal", strconv.Itoa(p.ID), "to", p.To.String(), "amount", strconv.FormatInt(p.Amount, 10))
}

// closePending drops a proposal that was just paid or cancelled from the
// pending list and from its proposer's open count.
func closePending(v *Vault, p *Proposal) {
	kept := make([]int, 0, len(v.Pending))
	for _, pid := range v.Pending {
		if pid != p.ID {
			kept = append(kept, pid)
		}
	}
	v.Pending = kept
	open, _ := v.OpenBy.Get(p.Proposer.String()).(int)
	if open <= 1 {
		v.OpenBy.Remove(p.Proposer.String())
	} else {
		v.OpenBy.Set(p.Proposer.String(), open-1)
	}
}

// isCleanText refuses control characters and invisible or
// direction-changing characters, which could make a name or memo display
// as something other than what it is.
func isCleanText(s string) bool {
	for _, r := range s {
		switch {
		case r < 0x20, r == 0x7f, r >= 0x80 && r <= 0x9f:
			return false
		case r >= 0x200b && r <= 0x200f, // zero-width, LRM/RLM
			r >= 0x202a && r <= 0x202e, // bidi embeddings and overrides
			r >= 0x2060 && r <= 0x206f, // word joiner, bidi isolates
			r == 0xfeff, r == 0x00ad,   // BOM, soft hyphen
			r == 0xfffd: // replacement char (invalid UTF-8)
			return false
		}
	}
	return true
}

// assertNoCoins refuses coins sent with any call but Deposit: they would
// land in the realm without belonging to a vault, and be lost. Panicking
// reverts the transaction, so the sender keeps them.
func assertNoCoins(cur realm) {
	if cur.Previous().IsUserCall() {
		require(len(unsafe.OriginSend()) == 0, "do not send coins with this call; use Deposit to fund a vault")
	}
}

// normalize lowercases an address. Bech32 accepts an all-uppercase form
// too, but callers always arrive lowercase: an uppercase signer would never
// match its owner, and could make a vault's threshold unreachable.
func normalize(a address) address {
	return address(strings.ToLower(a.String()))
}

func getProposal(v *Vault, id int) *Proposal {
	return v.Proposals.Get(key(id)).(*Proposal)
}

func getVault(id int) (*Vault, bool) {
	if id < 1 || id >= nextID {
		return nil, false
	}
	v, ok := vaults.Get(key(id)).(*Vault)
	return v, ok
}

func mustVault(id int) *Vault {
	v, ok := getVault(id)
	require(ok, "vault "+strconv.Itoa(id)+" not found")
	return v
}

func mustSigner(v *Vault, addr address) {
	require(contains(v.Signers, addr), "only signers of this vault can do this")
}

func mustPending(v *Vault, proposalID int) *Proposal {
	require(proposalID >= 1 && proposalID <= v.ProposalCount, "proposal "+strconv.Itoa(proposalID)+" not found")
	p := getProposal(v, proposalID)
	require(p.Status == StatusPending, "proposal is already "+p.Status.String())
	return p
}

func key(id int) string {
	s := strconv.Itoa(id)
	return strings.Repeat("0", 10-len(s)) + s
}

func contains(list []address, a address) bool { return indexOf(list, a) >= 0 }

func indexOf(list []address, a address) int {
	for i, x := range list {
		if x == a {
			return i
		}
	}
	return -1
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}
