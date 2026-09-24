package nft

import (
	"chain"
	"chain/runtime"
	"crypto/merkle"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bloom/v0"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	"gno.land/p/nt/bptree/v0"
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

var (
	// Admin account for the realm.
	// This account is only valid to set snapshot params, once setted minting
	// can start and the account becomes obsolete when the first NFT is minted.
	Admin *ownable.Ownable

	// Supply cap is the number of Settlers that can be minted.
	supplyCap = capacity

	// Root is the Merkle root value.
	root []byte

	// Total is the total number of leaves of the list of elegible accounts.
	total int

	// Tokens has every token, by ID (zero-padded, so it is in mint order).
	tokens = bptree.NewBPTree32()

	// Claimed has the ID of the token for each account.
	claimed = bptree.NewBPTree32()

	// Seen has the packed traits of the tokens, so that two Settlers are never the same.
	seen = newTraitsFilter()

	// Realm path is the path of this realm.
	realmPath string
)

// Token represents a Settler.
type token struct {
	owner  address
	traits uint32
}

func init(cur realm) {
	realmPath = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
	Admin = ownable.NewWithAddress(cur.Previous().Address())

	// Announce the new collection
	chain.Emit(
		"NewToken",
		"token", CollectionID(),
		"name", Name,
		"symbol", Symbol,
	)
}

// SetSnapshot opens the mint.
// It sets the Merkle root of the list of eligible accounts, in hex, and the
// number of accounts in the list. Only the owner can call it.
// It can be called again to correct a mistake until the first Settler is minted,
// from then on the list is frozen.
func SetSnapshot(cur realm, rootHex string, count int) {
	Admin.AssertOwnedBy(cur.Previous().Address())

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

// Mint mints a Settler to the caller and returns its id.
//
// The proof shows that the caller is in the list of eligible accounts.
// Proof format is "<index>.<aunts>".
func Mint(cur realm, proof string) int {
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
	var packed uint32
	for nonce := 0; ; nonce++ {
		if nonce == maxNonce {
			panic("could not find a new gnome, try again")
		}

		seed := generateSeed(caller, runtime.ChainHeight(), settlerID, nonce)
		traits := nft.NewTraits(seed)
		packed = nft.Pack(traits.Normalized())
		if !seen.ContainsString(strconv.FormatUint(uint64(packed), 10)) {
			break
		}
	}

	tokens.Set(makeKey(settlerID), token{owner: caller, traits: packed})
	seen.AddString(strconv.FormatUint(uint64(packed), 10))
	claimed.Set(caller.String(), settlerID)
	chain.Emit(
		"Transfer",
		"token", CollectionID(),
		"from", "",
		"to", caller.String(),
		"tokenId", strconv.Itoa(settlerID),
	)
	return settlerID
}

// Cap returns the number of Settlers that can be minted.
func Cap() int { return supplyCap }

// TotalSupply returns the number of Settlers minted so far.
func TotalSupply() int { return tokens.Size() }

// MerkleRoot returns the Merkle root of the list of eligible accounts, in hex.
func MerkleRoot() string { return hex.EncodeToString(root) }

// Total returns the number of eligible accounts in the list.
func Total() int { return total }

// CollectionID returns the ID that the events use for this collection.
func CollectionID() string {
	return runtime.ChainDomain() + realmPath + "." + Symbol + ".0000000"
}

// OwnerOf returns the owner account of a Settler.
func OwnerOf(settlerID int) address { return tokenOf(settlerID).owner }

// BalanceOf returns the number of Settlers of an account (0 or 1).
func BalanceOf(addr address) int {
	if claimed.Has(addr.String()) {
		return 1
	}
	return 0
}

// TokenOf returns the ID of the Settler of an account, or 0 if it has none.
func TokenOf(addr address) int {
	v := claimed.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int)
}

// TraitsOf returns the traits of a Settler.
func TraitsOf(settlerID int) nft.Traits { return nft.Unpack(tokenOf(settlerID).traits) }

func tokenOf(settlerID int) token {
	v := tokens.Get(makeKey(settlerID))
	if v == nil {
		panic("token not found")
	}
	return v.(token)
}

func newTraitsFilter() *bloom.Bloom {
	m := uint64(28756) // bits
	k := uint64(7)     // hashes
	return bloom.NewWithMK(m, k)
}

func generateSeed(caller address, height int64, settlerID, nonce int) string {
	input := caller.String() + ":" + strconv.FormatInt(height, 10) + ":" +
		strconv.Itoa(settlerID) + ":" + strconv.Itoa(nonce)
	sum := sha256.Sum256([]byte(input))
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
