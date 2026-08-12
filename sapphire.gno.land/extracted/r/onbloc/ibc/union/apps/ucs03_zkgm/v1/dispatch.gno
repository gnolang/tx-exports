package ucs03_zkgm

import (
	"bytes"

	types "gno.land/p/onbloc/ibc/union/types"

	"gno.land/p/nt/ufmt/v0"
	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	core "gno.land/r/onbloc/ibc/union/core"
)

// verifyInternal routes an instruction to its opcode-specific verifier (the send-side validation entry point).
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2742-L2796
func (v *ucs03ZkgmV1) verifyInternal(_ int, rlm realm, funds *funds, channelId types.ChannelId, path *u256.Uint, instruction z.Instruction) error {
	switch instruction.Opcode {
	case z.OP_TOKEN_ORDER:
		order, err := decodeOrderInstruction(instruction)
		if err != nil {
			return err
		}

		return v.verifyTokenOrderV2(0, rlm, funds, channelId, path, order)
	case z.OP_BATCH:
		batch, err := decodeBatchInstruction(instruction)
		if err != nil {
			return err
		}

		return v.verifyBatch(0, rlm, funds, channelId, path, batch)
	case z.OP_FORWARD:
		forward, err := decodeForwardInstruction(instruction)
		if err != nil {
			return err
		}

		return v.verifyForward(0, rlm, funds, channelId, forward)
	case z.OP_CALL:
		call, err := decodeCallInstruction(instruction)
		if err != nil {
			return err
		}

		return v.verifyCall(0, rlm, call)
	default:
		return makeError(errUnsupportedOpcode)
	}
}

// execFatal is a sentinel panic value.
//
// Unlike ordinary panics, values of this type are re-panicked by the recover
// handler so the VM can observe the failure after transaction rollback.
type execFatal struct{ msg string }

func (e execFatal) Error() string { return e.msg }

// dispatchExecutePacket routes a received instruction to its opcode handler, turning non-fatal errors into a failure ack.
func (v *ucs03ZkgmV1) dispatchExecutePacket(
	_ int, rlm realm,
	packet types.Packet,
	relayer address,
	relayerMsg []byte,
	salt [32]byte,
	path *u256.Uint,
	instruction z.Instruction,
	intent bool,
) (result types.RecvPacketResult, err error) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(execFatal); ok {
				panic(r)
			}

			result = failureResult(universalErrorAck())
			err = nil
		}
	}()

	switch instruction.Opcode {
	case z.OP_TOKEN_ORDER:
		order, err := decodeOrderInstruction(instruction)
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		return v.executeTokenOrderV2(0, rlm, packet, relayer, relayerMsg, salt, path, order, intent)
	case z.OP_BATCH:
		batch, err := decodeBatchInstruction(instruction)
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		ack, err := v.executeBatch(0, rlm, packet, relayer, relayerMsg, salt, path, batch, intent)
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		return core.NewRecvPacketResult(types.PacketStatusSuccess, ack), nil
	case z.OP_CALL:
		call, err := decodeCallInstruction(instruction)
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		return v.executeCall(0, rlm, packet, relayer, relayerMsg, path, call, intent)
	case z.OP_FORWARD:
		forward, err := decodeForwardInstruction(instruction)
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		return v.executeForward(0, rlm, packet, salt, path, forward, intent)
	default:
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), makeError(errUnsupportedOpcode)
	}
}

// acknowledgeInternal routes an acknowledgement to its opcode handler.
func (v *ucs03ZkgmV1) acknowledgeInternal(_ int, rlm realm, packet types.Packet, relayer address, salt [32]byte, path *u256.Uint, instruction z.Instruction, successful bool, ack []byte) error {
	switch instruction.Opcode {
	case z.OP_TOKEN_ORDER:
		order, err := decodeOrderInstruction(instruction)
		if err != nil {
			return err
		}

		var orderAck z.TokenOrderAck

		hasOrderAck := false

		if successful {
			decoded, err := z.DecodeTokenOrderAck(ack)
			if err != nil {
				return err
			}

			orderAck = decoded
			hasOrderAck = true
		}

		return v.acknowledgeTokenOrderV2(0, rlm, packet, relayer, salt, path, order, orderAck, hasOrderAck)
	case z.OP_BATCH:
		batch, err := decodeBatchInstruction(instruction)
		if err != nil {
			return err
		}

		return v.acknowledgeBatch(0, rlm, packet, relayer, salt, path, batch, successful, ack)
	// OP_FORWARD reference (_acknowledgeForward): https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/evm/contracts/apps/ucs/03-zkgm/Zkgm.sol#L688-L707
	case z.OP_FORWARD:
		forward, err := decodeForwardInstruction(instruction)
		if err != nil {
			return err
		}

		return v.acknowledgeInternal(0, rlm, packet, relayer, salt, forward.Path, forward.Instruction, successful, ack)
	case z.OP_CALL:
		call, err := decodeCallInstruction(instruction)
		if err != nil {
			return err
		}

		return v.acknowledgeCall(0, rlm, packet, path, call)
	default:
		return makeError(errUnsupportedOpcode)
	}
}

// timeoutInternal routes a timeout to its opcode handler.
func (v *ucs03ZkgmV1) timeoutInternal(_ int, rlm realm, packet types.Packet, salt [32]byte, path *u256.Uint, instruction z.Instruction) error {
	switch instruction.Opcode {
	case z.OP_TOKEN_ORDER:
		order, err := decodeOrderInstruction(instruction)
		if err != nil {
			return err
		}

		return v.refundV2(0, rlm, path, packet.SourceChannelId, order)
	case z.OP_BATCH:
		batch, err := decodeBatchInstruction(instruction)
		if err != nil {
			return err
		}

		return v.timeoutBatch(0, rlm, packet, salt, path, batch)
	// OP_FORWARD reference (_timeoutForward): https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/evm/contracts/apps/ucs/03-zkgm/Zkgm.sol#L842-L851
	case z.OP_FORWARD:
		forward, err := decodeForwardInstruction(instruction)
		if err != nil {
			return err
		}

		return v.timeoutInternal(0, rlm, packet, salt, forward.Path, forward.Instruction)
	case z.OP_CALL:
		call, err := decodeCallInstruction(instruction)
		if err != nil {
			return err
		}

		return v.timeoutCall(0, rlm, packet, path, call)
	default:
		return makeError(errUnsupportedOpcode)
	}
}

// decodeOrderInstruction decodes a v2 token order, rejecting unsupported instruction versions.
func decodeOrderInstruction(instruction z.Instruction) (z.TokenOrderV2, error) {
	if instruction.Version != z.INSTR_VERSION_2 {
		return z.TokenOrderV2{}, makeError(errUnsupportedTokenOrderVersion)
	}

	return z.DecodeTokenOrderV2(instruction.Operand)
}

// decodeCallInstruction decodes a call, rejecting unsupported instruction versions.
func decodeCallInstruction(instruction z.Instruction) (z.Call, error) {
	if instruction.Version != z.INSTR_VERSION_0 {
		return z.Call{}, makeError(errUnsupportedCallVersion)
	}

	return z.DecodeCall(instruction.Operand)
}

// decodeBatchInstruction decodes a batch, rejecting unsupported instruction versions.
func decodeBatchInstruction(instruction z.Instruction) (z.Batch, error) {
	if instruction.Version != z.INSTR_VERSION_0 {
		return z.Batch{}, makeError(errUnsupportedBatchVersion)
	}

	return z.DecodeBatch(instruction.Operand)
}

// decodeForwardInstruction decodes a forward, rejecting unsupported instruction versions.
func decodeForwardInstruction(instruction z.Instruction) (z.Forward, error) {
	if instruction.Version != z.INSTR_VERSION_0 {
		return z.Forward{}, makeError(errUnsupportedForwardVersion)
	}

	return z.DecodeForward(instruction.Operand)
}

// mustEncodeUniversalErrorAck returns the ABI-encoded failure acknowledgement
// `z.Ack{Tag: TAG_ACK_FAILURE, InnerAck: empty}` that zkgm-internal recv failures
// emit. The empty inner ack matches union's `Ack{tag: TAG_ACK_FAILURE, inner_ack:
// Default::default()}`; the encoded Ack itself is non-empty, satisfying core's
// non-empty acknowledgement requirement.
func mustEncodeUniversalErrorAck() []byte {
	bz, err := z.EncodeAck(z.Ack{
		Tag:      u256.NewUint(0),
		InnerAck: []byte{},
	})
	if err != nil {
		panic(err)
	}

	return bz
}

// failureResult wraps an ack as a failed recv result.
func failureResult(ack []byte) types.RecvPacketResult {
	return core.NewRecvPacketResult(types.PacketStatusFailure, ack)
}

// universalErrorAck returns the cached sentinel error acknowledgement.
func universalErrorAck() []byte {
	return mustEncodeUniversalErrorAck()
}

// tokenOrderDestinationChannel rejects the zero-channel sentinel so the
// derived destChan is safe to feed into UpdateChannelPath / PopChannelFromPath
// without colliding with the "no channel" slot. This mirrors the TokenOrder
// path helper's channel-zero rejection.
func tokenOrderDestinationChannel(channelId types.ChannelId) (uint32, error) {
	raw := uint32(channelId)
	if raw == 0 {
		return 0, makeError(errInvalidTokenOrderDestChannel)
	}

	return raw, nil
}

// isOnlyMakerAck reports whether ack is the only-maker sentinel.
func isOnlyMakerAck(ack []byte) bool {
	return bytes.Equal(ack, z.ACK_ERR_ONLY_MAKER)
}

// extractPanicMessage renders a recovered panic value as a string.
func extractPanicMessage(r any) string {
	switch v := r.(type) {
	case string:
		return v
	case error:
		return v.Error()
	default:
		return ufmt.Sprintf("%v", v)
	}
}
