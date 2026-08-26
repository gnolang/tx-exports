package zkgm

import (
	"crypto/keccak256"
	"encoding/binary"
	"encoding/hex"

	abi "gno.land/p/onbloc/encoding/abi"
	types "gno.land/p/onbloc/ibc/union/types"
	u256 "gno.land/p/onbloc/math/uint256"
)

const (
	ibcDenomPrefix         = "ibc/"
	tagCallProxy           = "ZKGM_CALL_PROXY"
	callProxyAccountPrefix = "zkgm1"
)

// PredictWrappedToken derives the legacy wrapped IBC denom for a v1 token order.
func PredictWrappedToken(path *u256.Uint, channelId uint32, baseToken []byte) string {
	if path == nil {
		path = u256.Zero()
	}

	bz, err := abi.Encode(PredictWrappedTokenSchema, []any{path, channelId, baseToken})
	if err != nil {
		panic(err)
	}

	h := keccak256.Sum256(bz)

	return ibcDenomPrefix + hex.EncodeToString(h[:20])
}

// PredictWrappedTokenV2 derives the IBC voucher denom for a v2 token order.
func PredictWrappedTokenV2(path *u256.Uint, channelId uint32, baseToken []byte, metadataImage [32]byte) string {
	if path == nil {
		path = u256.Zero()
	}

	image := u256.Zero().SetBytes(metadataImage[:])

	bz, err := abi.Encode(PredictV2Schema, []any{path, channelId, baseToken, image})
	if err != nil {
		panic(err)
	}

	h := keccak256.Sum256(bz)

	return ibcDenomPrefix + hex.EncodeToString(h[:20])
}

// MetadataImage returns keccak256(TokenMetadata), the on-chain identity of the
// metadata used to mint a voucher.
func MetadataImage(meta TokenMetadata) [32]byte {
	bz, err := EncodeTokenMetadata(meta)
	if err != nil {
		panic(err)
	}

	return keccak256.Sum256(bz)
}

// Uint256FromBytes32 converts a big-endian bytes32 value into a uint256.
func Uint256FromBytes32(bz [32]byte) *u256.Uint {
	return u256.Zero().SetBytes(bz[:])
}

// PredictCallProxyAccount derives a synthetic zkgm1 account for (path, channelId, sender).
// Fixed-width path/channelId plus a length-prefixed sender keep the preimage collision-free.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L3507-L3538
func PredictCallProxyAccount(path *u256.Uint, channelId types.ChannelId, sender []byte) string {
	if path == nil {
		path = u256.Zero()
	}
	pathBytes := Uint256ToBytes32(path)

	var channelBytes [4]byte
	binary.BigEndian.PutUint32(channelBytes[:], uint32(channelId))

	var senderLen [8]byte
	binary.BigEndian.PutUint64(senderLen[:], uint64(len(sender)))

	buf := make([]byte, 0, len(tagCallProxy)+len(pathBytes)+len(channelBytes)+len(senderLen)+len(sender))
	buf = append(buf, tagCallProxy...)
	buf = append(buf, pathBytes[:]...)
	buf = append(buf, channelBytes[:]...)
	buf = append(buf, senderLen[:]...)
	buf = append(buf, sender...)

	h := keccak256.Sum256(buf)

	return callProxyAccountPrefix + hex.EncodeToString(h[:20])
}
