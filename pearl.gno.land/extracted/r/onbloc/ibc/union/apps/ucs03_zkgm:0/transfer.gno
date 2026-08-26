package ucs03_zkgm

import (
	"encoding/hex"

	types "gno.land/p/onbloc/ibc/union/types"

	z "gno.land/p/onbloc/ibc/union/zkgm"
)

func Send(cur realm, channelId types.ChannelId, timeoutTimestamp types.Timestamp, salt [32]byte, instruction z.Instruction) types.Packet {
	assertIsNotPaused()

	return mustGetImpl().Send(0, cur, channelId, timeoutTimestamp, salt, instruction)
}

// SendRaw sends a ZKGM packet from hex-encoded instruction fields. Use this
// entry point from gnokey maketx call (not maketx run) so OriginSend captures
// any native coins attached with -send for escrow-bearing instructions.
//
//   - channelId: local source IBC channel id on this chain.
//   - timeoutTimestamp: packet expiry in nanoseconds since the Unix epoch.
//   - saltHex: 32-byte send salt as hex; an optional 0x prefix is accepted.
//   - version: instruction version byte (e.g. 2 for TokenOrderV2).
//   - opcode: instruction opcode (0=Forward, 1=Call, 2=Batch, 3=TokenOrder).
//   - operandHex: ABI-encoded instruction operand as hex; 0x prefix optional.
func SendRaw(cur realm, channelId uint32, timeoutTimestamp uint64, saltHex string, version uint8, opcode uint8, operandHex string) types.Packet {
	assertIsNotPaused()

	saltBytes, err := parseHex(saltHex)
	if err != nil {
		panic(err)
	}

	if len(saltBytes) != 32 {
		panic(ErrInvalidSaltLength)
	}

	var salt [32]byte

	copy(salt[:], saltBytes)

	operandBytes, err := parseHex(operandHex)
	if err != nil {
		panic(err)
	}

	instruction := z.Instruction{
		Version: version,
		Opcode:  opcode,
		Operand: operandBytes,
	}

	return mustGetImpl().Send(0, cur, types.ChannelId(channelId), types.Timestamp(timeoutTimestamp), salt, instruction)
}

func parseHex(s string) ([]byte, error) {
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		s = s[2:]
	}

	bz, err := hex.DecodeString(s)
	if err != nil {
		return nil, err
	}

	return bz, nil
}
