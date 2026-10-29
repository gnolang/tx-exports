package zkgm

import (
	"crypto/keccak256"
	"encoding/hex"

	abi "gno.land/p/onbloc/encoding/abi"
	types "gno.land/p/onbloc/ibc/union/types"
	u256 "gno.land/p/onbloc/math/uint256"
)

const (
	ibcDenomPrefix = "ibc/"
	tagCallProxy   = "ZKGM_CALL_PROXY"
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

// PredictCallProxyAccount returns the synthetic Gno address that represents
// the given (path, destinationChannel, sender) tuple as a callable account.
//
// key = zkgm1<first-20-bytes-of-keccak(ZKGM_CALL_PROXY || path || channelId || sender)>
func PredictCallProxyAccount(path *u256.Uint, channelId types.ChannelId, sender []byte) string {
	var pathBytes [32]byte
	if path != nil {
		pathBytes = Uint256ToBytes32(path)
	}

	channel := channelId.String()
	buf := make([]byte, 0, len(tagCallProxy)+len(pathBytes)+len(channel)+len(sender))
	buf = append(buf, tagCallProxy...)
	buf = append(buf, pathBytes[:]...)
	buf = append(buf, channel...)
	buf = append(buf, sender...)

	h := keccak256.Sum256(buf)

	return "zkgm1" + hex.EncodeToString(h[:20])
}
