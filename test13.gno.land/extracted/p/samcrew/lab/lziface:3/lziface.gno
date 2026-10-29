package lziface

import (
	"crypto/sha256"
	"encoding/binary"
	"chain/runtime"

	"gno.land/p/samcrew/deps/onbloc/uint256"
)

var EMPTY_PAYLOAD_HASH = [32]byte{}

type Origin struct {
	SrcEID uint32
	Sender [32]byte
	Nonce  uint64
}

type OApp interface {
	AllowInitializePath(origin *Origin) bool
	LZReceive(cur realm, origin *Origin, guid [32]byte, message []byte, executor runtime.Realm, extraData []byte)
}

// MessagingParams contains all parameters needed for LayerZero message quoting/sending
type MessagingParams struct {
	DstEID       uint32   // Destination endpoint ID (uint32 in Solidity)
	Receiver     [32]byte // bytes32 in Solidity (fixed-size 32 byte array)
	Message      []byte   // bytes in Solidity (dynamic byte array)
	Options      []byte   // bytes in Solidity (dynamic byte array)
	PayInLzToken bool     // bool in Solidity
}

// MessagingFee represents the fee structure for LayerZero messages
type MessagingFee struct {
	NativeFee  *uint256.Uint // uint256 in Solidity
	LzTokenFee *uint256.Uint // uint256 in Solidity
}

// MessagingReceipt contains the result of a message send operation
type MessagingReceipt struct {
	Guid  [32]byte      // bytes32 in Solidity
	Nonce uint64        // uint64 in Solidity
	Fee   *MessagingFee // Nested struct
}

func GenerateGUID(
	nonce uint64,
	srcEID uint32,
	senderAddr address,
	dstEID uint32,
	receiver [32]byte,
) [32]byte {
	packed := make([]byte, 8+4+32+4+32)

	binary.BigEndian.PutUint64(packed, nonce)

	binary.BigEndian.PutUint32(packed[8:], srcEID)

	lzAddr := AddressToBytes32(senderAddr)
	copy(packed[8+4:], lzAddr[:])

	binary.BigEndian.PutUint32(packed[8+4+32:], dstEID)

	copy(packed[8+4+32+4:], receiver[:])

	return sha256.Sum256(packed)
}

type SendLib interface {
	MessageLib // Embed the base interface

	// Send transmits a packet and returns fee and encoded packet
	Send(cur realm, packet *GnoPacket, options []byte, payInLzToken bool) (*MessagingFee, []byte)

	// Quote calculates the fee for sending a packet
	Quote(packet *GnoPacket, options []byte, payInLzToken bool) *MessagingFee

	// SetTreasury sets the treasury address
	// SetTreasury(treasury string)

	// WithdrawFee withdraws native tokens to the specified address
	// WithdrawFee(to address, amount *uint256.Uint)

	// WithdrawLzTokenFee withdraws LZ tokens to the specified address
	// WithdrawLzTokenFee(lzToken, to address, amount *uint256.Uint)
}
