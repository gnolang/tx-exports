// Package hyperlane is Hyperlane's wire format, byte for byte, for a mailbox on gno.land: the message and its id,
// the incremental merkle tree the validators checkpoint, the checkpoint digest they sign, a warp route's token
// message, and the multisig check a destination runs over the signatures. It keeps no state and reads no chain.
//
// Sources (hyperlane-monorepo 3cd9308, 2026-10-10): solidity/contracts/libs/Message.sol, Merkle.sol,
// CheckpointLib.sol, TypeCasts.sol, token/libs/TokenMessage.sol, isms/libs/MessageIdMultisigIsmMetadata.sol; the
// vectors in vectors/ are this package's tests.
//
// One departure, and only on the gno side: gno.land has no secp256k1, so the multisig a gno mailbox runs
// (VerifyMultisig) takes ed25519 signatures over the same checkpoint digest Hyperlane's validators sign with
// secp256k1, and each signature names its validator in one leading byte (65 bytes a signature, as in Hyperlane's
// metadata). Messages, ids, the tree and the digest are Hyperlane's exactly, so the other chain's ISM checks a gno
// checkpoint with its stock code.
package hyperlane

import (
	"crypto/bech32"
	"crypto/ed25519"
	"crypto/keccak256"
	"encoding/binary"
	"errors"
)

const (
	// Version is the message version every Hyperlane mailbox speaks (Versioned.VERSION).
	Version = 3
	// HeaderLen is the message header: version 1, nonce 4, origin 4, sender 32, destination 4, recipient 32.
	HeaderLen = 77
	// TreeDepth is the merkle tree's depth (Merkle.sol TREE_DEPTH).
	TreeDepth = 32
	// MaxLeaves is how many leaves the tree takes (Merkle.sol MAX_LEAVES, 2^32 - 1).
	MaxLeaves = 1<<TreeDepth - 1

	sigLen  = 65 // a signature's slot in multisig metadata: Hyperlane's r‖s‖v, here validator byte ‖ ed25519
	metaLen = 68 // the metadata's fixed head: merkle tree hook 32, root 32, index 4
)

// ------------------------------------------------------------- message --

// Message is a Hyperlane message (Message.sol). Sender and recipient are 32 bytes: a 20-byte address is padded on
// the left with twelve zero bytes (AddressToBytes32); a Solana pubkey is its 32 bytes as they are.
type Message struct {
	Version     uint8
	Nonce       uint32
	Origin      uint32
	Sender      [32]byte
	Destination uint32
	Recipient   [32]byte
	Body        []byte
}

// Bytes is the message on the wire: abi.encodePacked of the fields, big-endian, no length prefixes.
func (m Message) Bytes() []byte {
	b := make([]byte, 0, HeaderLen+len(m.Body))
	b = append(b, m.Version)
	b = binary.BigEndian.AppendUint32(b, m.Nonce)
	b = binary.BigEndian.AppendUint32(b, m.Origin)
	b = append(b, m.Sender[:]...)
	b = binary.BigEndian.AppendUint32(b, m.Destination)
	b = append(b, m.Recipient[:]...)
	return append(b, m.Body...)
}

// ID is the message's id: keccak256 of the whole message, body included.
func (m Message) ID() [32]byte { return ID(m.Bytes()) }

// ID is the id of a message as it came off the wire.
func ID(raw []byte) [32]byte { return keccak256.Sum256(raw) }

// ParseMessage reads a message off the wire. The body is a copy.
func ParseMessage(b []byte) (Message, error) {
	if len(b) < HeaderLen {
		return Message{}, errors.New("hyperlane: message shorter than its header")
	}
	var m Message
	m.Version = b[0]
	m.Nonce = binary.BigEndian.Uint32(b[1:5])
	m.Origin = binary.BigEndian.Uint32(b[5:9])
	copy(m.Sender[:], b[9:41])
	m.Destination = binary.BigEndian.Uint32(b[41:45])
	copy(m.Recipient[:], b[45:77])
	m.Body = append([]byte(nil), b[HeaderLen:]...)
	return m, nil
}

// ---------------------------------------------------------- addresses --

// AddressToBytes32 is a gno address as Hyperlane carries one: twelve zero bytes, then the address's twenty
// (TypeCasts.addressToBytes32).
func AddressToBytes32(a address) ([32]byte, error) {
	var out [32]byte
	hrp, bz, err := bech32.DecodeToBase256(string(a))
	if err != nil {
		return out, err
	}
	if hrp != "g" || len(bz) != 20 {
		return out, errors.New("hyperlane: not a gno address: " + string(a))
	}
	copy(out[12:], bz)
	return out, nil
}

// Bytes32ToAddress is the gno address a bytes32 names: twelve zero bytes, then the address's twenty (§13: the top
// 12 bytes must be zero). A bytes32 whose top twelve bytes are not zero — a raw Solana pubkey, say — is no gno
// address and errors, rather than landing on the address its last twenty bytes happen to spell, which nobody
// holds (the EVM's TypeCasts.bytes32ToAddress truncates; a gno route sweeps such a recipient instead, §5.4).
func Bytes32ToAddress(b [32]byte) (address, error) {
	for _, c := range b[:12] {
		if c != 0 {
			return "", errors.New("hyperlane: not a gno address: the top twelve bytes are not zero")
		}
	}
	s, err := bech32.EncodeFromBase256("g", b[12:])
	if err != nil {
		panic(err) // twenty bytes always encode
	}
	return address(s), nil
}

// -------------------------------------------------------- merkle tree --

// Tree is Hyperlane's incremental merkle tree (Merkle.sol, the eth2 deposit contract's): depth 32, nodes
// keccak256(left ‖ right), leaves the message ids themselves. The zero value is the empty tree.
type Tree struct {
	Branch [TreeDepth][32]byte
	Count  uint32
}

// zeroes[i] is the root of an empty subtree of height i: Z0 = 0, Zi+1 = keccak256(Zi ‖ Zi).
var zeroes = func() [TreeDepth][32]byte {
	var z [TreeDepth][32]byte
	for i := 1; i < TreeDepth; i++ {
		z[i] = hash2(z[i-1], z[i-1])
	}
	return z
}()

func hash2(a, b [32]byte) [32]byte {
	buf := make([]byte, 64)
	copy(buf, a[:])
	copy(buf[32:], b[:])
	return keccak256.Sum256(buf)
}

// Insert adds a leaf at index Count.
func (t *Tree) Insert(leaf [32]byte) {
	if t.Count >= MaxLeaves {
		panic("hyperlane: merkle tree full")
	}
	t.Count++
	size := t.Count
	node := leaf
	for i := 0; i < TreeDepth; i++ {
		if size&1 == 1 {
			t.Branch[i] = node
			return
		}
		node = hash2(t.Branch[i], node)
		size >>= 1
	}
	panic("hyperlane: merkle insert fell through") // unreachable: Count < 2^32 has a bit set below 32
}

// Root is the tree's root now (Merkle.sol root(), with the zero hashes).
func (t *Tree) Root() [32]byte {
	var cur [32]byte
	for i := 0; i < TreeDepth; i++ {
		if (t.Count>>uint(i))&1 == 1 {
			cur = hash2(t.Branch[i], cur)
		} else {
			cur = hash2(cur, zeroes[i])
		}
	}
	return cur
}

// ---------------------------------------------------------- checkpoint --

// DomainHash binds a checkpoint to its origin chain and that chain's merkle tree hook: keccak256(origin ‖ hook ‖
// "HYPERLANE"), 45 bytes hashed (CheckpointLib.domainHash). On Solana the hook is the mailbox program's id.
func DomainHash(origin uint32, hook [32]byte) [32]byte {
	b := make([]byte, 0, 45)
	b = binary.BigEndian.AppendUint32(b, origin)
	b = append(b, hook[:]...)
	b = append(b, "HYPERLANE"...)
	return keccak256.Sum256(b)
}

// CheckpointDigest is what a validator signs for one message: the EIP-191 personal-message hash of
// keccak256(domainHash ‖ root ‖ index ‖ messageID) (CheckpointLib.digest). root and index are the origin tree's
// right after messageID went in at index; a message-id ISM does not check them, only the signatures over them.
func CheckpointDigest(origin uint32, hook, root [32]byte, index uint32, messageID [32]byte) [32]byte {
	d := DomainHash(origin, hook)
	b := make([]byte, 0, 100)
	b = append(b, d[:]...)
	b = append(b, root[:]...)
	b = binary.BigEndian.AppendUint32(b, index)
	b = append(b, messageID[:]...)
	return EthSignedMessageHash(keccak256.Sum256(b))
}

// EthSignedMessageHash is EIP-191's hash of a 32-byte message: keccak256("\x19Ethereum Signed Message:\n32" ‖ h).
func EthSignedMessageHash(h [32]byte) [32]byte {
	b := append([]byte("\x19Ethereum Signed Message:\n32"), h[:]...)
	return keccak256.Sum256(b)
}

// -------------------------------------------------------- token message --

// TokenMessage is a warp route's body (TokenMessage.sol): the recipient on the destination, the amount as a
// big-endian uint256, then metadata (usually none).
func TokenMessage(recipient [32]byte, amount uint64, metadata []byte) []byte {
	b := make([]byte, 0, 64+len(metadata))
	b = append(b, recipient[:]...)
	b = append(b, make([]byte, 24)...)
	b = binary.BigEndian.AppendUint64(b, amount)
	return append(b, metadata...)
}

// ParseTokenMessage reads a warp route's body. An amount past 2^64 - 1 is refused; trailing metadata (Solana's
// TransferRemoteWithMemo writes a memo there) is returned, not refused.
func ParseTokenMessage(b []byte) (recipient [32]byte, amount uint64, metadata []byte, err error) {
	if len(b) < 64 {
		return recipient, 0, nil, errors.New("hyperlane: token message shorter than 64 bytes")
	}
	for _, c := range b[32:56] {
		if c != 0 {
			return recipient, 0, nil, errors.New("hyperlane: token amount past 64 bits")
		}
	}
	copy(recipient[:], b[:32])
	return recipient, binary.BigEndian.Uint64(b[56:64]), append([]byte(nil), b[64:]...), nil
}

// ------------------------------------------------------------ multisig --

// Checkpoint is the head of multisig metadata: the origin's merkle tree hook, and the root and index the
// validators signed (MessageIdMultisigIsmMetadata).
type Checkpoint struct {
	Hook  [32]byte
	Root  [32]byte
	Index uint32
}

// Signature is one validator's ed25519 signature and its place in the validator set.
type Signature struct {
	Validator uint8
	Sig       [64]byte
}

// MultisigMetadata lays out what a relayer hands a gno mailbox: hook 32 ‖ root 32 ‖ index 4, then 65 bytes a
// signature: the validator's index in the set, then its ed25519 signature over CheckpointDigest. Validator
// indexes strictly increase, so no validator counts twice.
func MultisigMetadata(c Checkpoint, sigs []Signature) []byte {
	b := make([]byte, 0, metaLen+sigLen*len(sigs))
	b = append(b, c.Hook[:]...)
	b = append(b, c.Root[:]...)
	b = binary.BigEndian.AppendUint32(b, c.Index)
	for _, s := range sigs {
		b = append(b, s.Validator)
		b = append(b, s.Sig[:]...)
	}
	return b
}

// ParseMultisigMetadata reads metadata laid out by MultisigMetadata.
func ParseMultisigMetadata(b []byte) (Checkpoint, []Signature, error) {
	var c Checkpoint
	if len(b) < metaLen || (len(b)-metaLen)%sigLen != 0 {
		return c, nil, errors.New("hyperlane: metadata is not 68 bytes and whole 65-byte signatures")
	}
	copy(c.Hook[:], b[0:32])
	copy(c.Root[:], b[32:64])
	c.Index = binary.BigEndian.Uint32(b[64:68])
	n := (len(b) - metaLen) / sigLen
	sigs := make([]Signature, n)
	for i := 0; i < n; i++ {
		o := metaLen + sigLen*i
		sigs[i].Validator = b[o]
		copy(sigs[i].Sig[:], b[o+1:o+sigLen])
	}
	return c, sigs, nil
}

// VerifyMultisig is a message-id multisig ISM over ed25519: the first threshold signatures in metadata must be
// valid signatures, by distinct validators in increasing order, over the checkpoint digest of this message from
// its own origin. validators are ed25519 public keys of 32 bytes. Signatures past the threshold are not read.
func VerifyMultisig(validators [][]byte, threshold int, metadata, message []byte) error {
	if threshold < 1 || threshold > len(validators) {
		return errors.New("hyperlane: no usable validator set for this origin")
	}
	m, err := ParseMessage(message)
	if err != nil {
		return err
	}
	c, sigs, err := ParseMultisigMetadata(metadata)
	if err != nil {
		return err
	}
	if len(sigs) < threshold {
		return errors.New("hyperlane: fewer signatures than the threshold")
	}
	digest := CheckpointDigest(m.Origin, c.Hook, c.Root, c.Index, ID(message))
	last := -1
	for _, s := range sigs[:threshold] {
		v := int(s.Validator)
		if v <= last {
			return errors.New("hyperlane: signatures out of validator order")
		}
		if v >= len(validators) {
			return errors.New("hyperlane: signature names no validator")
		}
		if !ed25519.Verify(validators[v], digest[:], s.Sig[:]) {
			return errors.New("hyperlane: a signature does not verify")
		}
		last = v
	}
	return nil
}
