package nft

import (
	"chain"
	"chain/runtime"
	"crypto/merkle"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bloom"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/mdalert/v0"
	"gno.land/p/nt/ownable/v0"
)

const (
	// Name is the NFT token's name.
	Name = "Settlers"

	// Symbol is the NFT token's symbol.
	Symbol = "SETTLER"

	// Capacity is the total number of Settlers that can be minted.
	capacity = 3000

	// Max nonce is how many gnomes are tried for a token before giving up,
	// when the ones that come out are already taken.
	maxNonce = 64

	// Max aunts is the longest proof accepted.
	maxAunts = 40
)

// ErrSoulbound is returned for operation that are not allowed on a soulbound NFT.
var ErrSoulbound = errors.New("settlers are soulbound, they can't be transferred or approved")

var (
	// Realm path is the path of this realm.
	RealmPath string

	// Notice is a realm-wide message the admin can post at any time, shown at the top of the page.
	// It never affects SVG, URI or Markdown, it is purely informational.
	Notice string

	// NoticeType is the style Notice is shown as.
	NoticeType mdalert.Type

	// Admin account for the realm.
	// This account is only valid to set snapshot params, once setted minting
	// can start and after the first NFT is minted the account is not allowed to change
	// snapshot params anymore.
	// It is always allowed to post or clear realm-wide notices.
	admin *ownable.Ownable

	// Supply cap is the number of Settlers that can be minted.
	supplyCap = capacity

	// Root is the Merkle root value.
	root []byte

	// Total is the total number of leaves of the list of elegible accounts.
	total int

	// Collection is the GRC721 token, it keeps the owners and balances and emits the standard events.
	collection *grc721.Token

	// Ledger is the writable side of the collection, only used to mint.
	ledger *grc721.PrivateLedger

	// Tokens has the packed traits of every token, by ID (zero-padded, so it is in mint order).
	tokens = bptree.NewBPTree32()

	// Claimed has the ID of the token for each account.
	claimed = bptree.NewBPTree32()

	// Seen traits has the packed traits of minted tokens to check that two Settlers are never the same.
	seenTraits = newTraitsFilter()
)

func init(cur realm) {
	RealmPath = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
	admin = ownable.NewWithAddress(cur.Previous().Address())
	collection, ledger = newCollection(cur)
}

// Soulbound is a GRC721 extension that aborts any transfer of a Settler.
// The realm never exposes a teller that can write, so a transfer can't be started,
// this makes sure that it could never finish either.
type soulbound struct{}

func (soulbound) ExtensionKind() string                       { return "soulbound" }
func (soulbound) OnMint(address, grc721.TokenID)              {}
func (soulbound) OnTransfer(address, address, grc721.TokenID) { panic(ErrSoulbound) }
func (soulbound) OnBurn(grc721.TokenID)                       {}

// newCollection creates the GRC721 token of the Settlers.
func newCollection(cur realm) (*grc721.Token, *grc721.PrivateLedger) {
	tok, led := grc721.NewToken(Name, Symbol, 0, cur)
	led.RegisterExtension(soulbound{})
	return tok, led
}

// SetSnapshot opens the mint.
// It sets the Merkle root of the list of eligible accounts, in hex, and the
// number of accounts in the list. Only the owner can call it.
// It can be called again to correct a mistake until the first Settler is minted,
// from then on the list is frozen.
func SetSnapshot(cur realm, rootHex string, count int) {
	assertIsCurrent(cur)
	admin.AssertOwnedBy(cur.Previous().Address())

	if tokens.Size() > 0 {
		panic("the snapshot is frozen: Settlers were already minted")
	}

	bz, err := hex.DecodeString(rootHex)
	if err != nil || len(bz) != 32 {
		panic("the root must be 32 bytes in hex")
	}

	if count < 1 {
		panic("the list must have at least one account")
	}

	root = bz
	total = count
	chain.Emit(
		"SnapshotSet",
		"root", rootHex,
		"total", strconv.Itoa(count),
	)
}

// Admin returns the address of the admin account.
func Admin() address { return admin.Owner() }

// TransferAdmin makes another account the admin. Only the admin can call it.
func TransferAdmin(cur realm, newAdmin address) {
	assertIsCurrent(cur)
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err)
	}
}

// SetNotice posts a realm-wide message, shown at the top of the page.
func SetNotice(cur realm, alertType mdalert.Type, msg string) {
	assertIsCurrent(cur)
	admin.AssertOwnedBy(cur.Previous().Address())
	assertIsValidAlertType(alertType)

	NoticeType = alertType
	Notice = msg
	chain.Emit("NoticeSet", "type", string(alertType))
}

// ClearNotice removes the current notice.
func ClearNotice(cur realm) {
	assertIsCurrent(cur)
	admin.AssertOwnedBy(cur.Previous().Address())

	NoticeType = ""
	Notice = ""
	chain.Emit("NoticeCleared")
}

// Mint mints a Settler to the caller and returns its ID.
//
// The proof shows that the caller is in the list of eligible accounts.
// Proof format is "<index>.<aunts>".
// Only user accounts can mint, either with a call or a run transaction, realms can't.
func Mint(cur realm, proof string) grc721.TokenID {
	assertIsCurrent(cur)
	if !cur.Previous().IsUser() {
		panic("only user accounts can mint")
	}

	if len(root) == 0 {
		panic("the mint is not open yet")
	}

	minted := tokens.Size()
	if minted >= supplyCap {
		panic("sold out")
	}

	caller := cur.Previous().Address()
	if claimed.Has(caller.String()) {
		panic("this account has already minted")
	}

	index, aunts, err := splitProof(proof)
	if err != "" {
		panic(err)
	}

	if !merkle.VerifySimpleProof(root, []byte(caller), index, total, aunts) {
		panic("the proof is not valid for this account: " + caller.String())
	}

	settlerID := minted + 1
	prefix := seedPrefix(caller, settlerID)

	var (
		packed    uint32
		packedKey string
	)
	for nonce := 0; ; nonce++ {
		if nonce == maxNonce {
			panic("could not find a new gnome, try again")
		}

		seed := hashSeed(prefix, nonce)
		traits := nft.NewTraits(seed)
		packed = nft.Pack(traits.Normalized())
		packedKey = strconv.FormatUint(uint64(packed), 10)
		if !seenTraits.ContainsString(packedKey) {
			break
		}
	}

	tid := tokenID(settlerID)
	if err := ledger.Mint(caller, tid); err != nil {
		panic(err)
	}

	tokens.Set(makeKey(settlerID), packed)
	seenTraits.AddString(packedKey)
	claimed.Set(caller.String(), tid)
	return tid
}

// Cap returns the number of Settlers that can be minted.
func Cap() int { return supplyCap }

// MerkleRoot returns the Merkle root of the list of eligible accounts, in hex.
func MerkleRoot() string { return hex.EncodeToString(root) }

// Total returns the number of eligible accounts in the list.
func Total() int { return total }

// TokenOf returns the ID of the Settler of an account, or an empty ID if it has none.
func TokenOf(addr address) grc721.TokenID {
	v := claimed.Get(addr.String())
	if v == nil {
		return ""
	}
	return v.(grc721.TokenID)
}

// TraitsOf returns the traits of a Settler.
func TraitsOf(tid grc721.TokenID) (nft.Traits, error) {
	packed, ok := traitsOf(tid)
	if !ok {
		return nft.Traits{}, grc721.ErrInvalidTokenId
	}
	return nft.Unpack(packed), nil
}

// traitsOf returns the packed traits of a Settler, or false if the ID is not a minted Settler.
func traitsOf(tid grc721.TokenID) (uint32, bool) {
	settlerID, ok := parseTokenID(tid)
	if !ok {
		return 0, false
	}

	v := tokens.Get(makeKey(settlerID))
	if v == nil {
		return 0, false
	}
	return v.(uint32), true
}

// tokenID returns the GRC721 ID of a Settler number.
func tokenID(settlerID int) grc721.TokenID {
	return grc721.TokenID(strconv.Itoa(settlerID))
}

// parseTokenID returns the Settler number of an ID, only for the canonical form ("1", not "01" or "+1").
func parseTokenID(tid grc721.TokenID) (int, bool) {
	settlerID, err := strconv.Atoi(string(tid))
	if err != nil || settlerID < 1 || strconv.Itoa(settlerID) != string(tid) {
		return 0, false
	}
	return settlerID, true
}

func newTraitsFilter() *bloom.Bloom {
	m := uint64(28756) // bits
	k := uint64(7)     // hashes
	return bloom.NewWithMK(m, k)
}

func generateSeed(caller address, settlerID, nonce int) string {
	return hashSeed(seedPrefix(caller, settlerID), nonce)
}

func seedPrefix(caller address, settlerID int) string {
	return strconv.FormatInt(time.Now().UnixNano(), 10) + ":" + caller.String() +
		":" + strconv.Itoa(settlerID) + ":"
}

func hashSeed(prefix string, nonce int) string {
	sum := sha256.Sum256([]byte(prefix + strconv.Itoa(nonce)))
	return hex.EncodeToString(sum[:])
}

func splitProof(proof string) (int, []byte, string) {
	dot := strings.Index(proof, ".")
	if dot < 1 {
		return 0, nil, "the proof must be <index>.<aunts>"
	}

	index, err := strconv.Atoi(proof[:dot])
	if err != nil || index < 0 || index >= total {
		return 0, nil, "the index of the proof is not valid"
	}

	aunts, err := hex.DecodeString(proof[dot+1:])
	if err != nil || len(aunts)%32 != 0 || len(aunts) > 32*maxAunts {
		return 0, nil, "the aunts of the proof must be hashes of 32 bytes in hex"
	}
	return index, aunts, ""
}

func makeKey(settlerID int) string {
	s := strconv.Itoa(settlerID)
	return strings.Repeat("0", 5-len(s)) + s
}

func assertIsCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("unauthorized")
	}
}

func assertIsValidAlertType(t mdalert.Type) {
	switch t {
	case mdalert.TypeCaution, mdalert.TypeInfo, mdalert.TypeNote,
		mdalert.TypeSuccess, mdalert.TypeTip, mdalert.TypeWarning:
		return
	}
	panic("invalid notice type")
}
