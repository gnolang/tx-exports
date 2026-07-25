package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"

	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
)

// verifyBatch verifies each allowed child instruction against the shared funds budget.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2941-L2967
func (v *ucs03ZkgmV1) verifyBatch(_ int, rlm realm, funds *funds, channelId types.ChannelId, path *u256.Uint, batch z.Batch) error {
	for _, instruction := range batch.Instructions {
		if !isAllowedBatchInstruction(instruction.Opcode) {
			return makeError(errInvalidBatchInstruction)
		}

		if err := v.verifyInternal(0, rlm, funds, channelId, path, instruction); err != nil {
			return err
		}
	}

	return nil
}

// executeBatch runs each child in order, aborting the whole batch on an only-maker child.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L1686-L1726
func (v *ucs03ZkgmV1) executeBatch(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte, salt [32]byte, path *u256.Uint, batch z.Batch, intent bool) ([]byte, error) {
	acks := make([][]byte, len(batch.Instructions))

	// NOTE: batch.Instructions remains uncapped until the Union reference defines
	// a maximum. Each child runs dispatchExecutePacket, including ABI decode and
	// keccak work, so execution cost scales with child count.
	for i, instruction := range batch.Instructions {
		if !isAllowedBatchInstruction(instruction.Opcode) {
			panic(execFatal{makeError(errInvalidBatchInstruction).Error()})
		}

		childSalt := z.DeriveBatchSalt(u256.NewUint(uint64(i)), salt)

		childRes, err := v.dispatchExecutePacket(0, rlm, packet, relayer, relayerMsg, childSalt, path, instruction, intent)
		if err != nil {
			panic(execFatal{err.Error()})
		}

		childAck := childRes.Acknowledgement
		if len(childAck) == 0 {
			// empty ack is unrecoverable once earlier children have committed.
			panic(execFatal{"batch child returned empty ack"})
		}
		// A single only-maker child aborts the entire batch: return the sentinel up
		// to the recv boundary (OnRecvPacket / OnIntentRecvPacket), which panics on
		// it and reverts the whole recv tx — so already-processed children's
		// mutations do NOT stand. Mirrors union's reply handler returning
		// Err(OnlyMaker) on an only-maker batch ack (contract.rs L2528-2530).
		if isOnlyMakerAck(childAck) {
			return types.CloneBytes(z.ACK_ERR_ONLY_MAKER), nil
		}

		acks[i] = childAck
	}

	batchAckBytes, err := z.EncodeBatchAck(z.BatchAck{Acknowledgements: acks})
	if err != nil {
		panic(execFatal{err.Error()})
	}

	ack, err := z.EncodeAck(z.Ack{Tag: tagAckSuccess(), InnerAck: batchAckBytes})
	if err != nil {
		panic(execFatal{err.Error()})
	}

	return ack, nil
}

// acknowledgeBatch fans the outer ack out to each child instruction.
func (v *ucs03ZkgmV1) acknowledgeBatch(_ int, rlm realm, packet types.Packet, relayer address, salt [32]byte, path *u256.Uint, batch z.Batch, successful bool, ack []byte) error {
	var batchAck z.BatchAck

	if successful {
		decoded, err := z.DecodeBatchAck(ack)
		if err != nil {
			return err
		}

		batchAck = decoded
		if len(batchAck.Acknowledgements) != len(batch.Instructions) {
			return makeError(errBatchAckCountMismatch)
		}
	}

	for i, instruction := range batch.Instructions {
		var childAck []byte

		childSuccessful := successful

		if successful {
			decodedChildAck, err := z.DecodeAck(batchAck.Acknowledgements[i])
			if err != nil {
				return err
			}

			childSuccessful = decodedChildAck.Tag != nil && decodedChildAck.Tag.Eq(tagAckSuccess())
			childAck = decodedChildAck.InnerAck
		}

		childSalt := z.DeriveBatchSalt(u256.NewUint(uint64(i)), salt)
		if err := v.acknowledgeInternal(0, rlm, packet, relayer, childSalt, path, instruction, childSuccessful, childAck); err != nil {
			return err
		}
	}

	return nil
}

// timeoutBatch fans the timeout out to each child instruction.
func (v *ucs03ZkgmV1) timeoutBatch(_ int, rlm realm, packet types.Packet, salt [32]byte, path *u256.Uint, batch z.Batch) error {
	for i, instruction := range batch.Instructions {
		childSalt := z.DeriveBatchSalt(u256.NewUint(uint64(i)), salt)
		if err := v.timeoutInternal(0, rlm, packet, childSalt, path, instruction); err != nil {
			return err
		}
	}

	return nil
}

// isAllowedBatchInstruction reports whether opcode may appear in a batch.
func isAllowedBatchInstruction(opcode uint8) bool {
	return opcode == z.OP_CALL || opcode == z.OP_TOKEN_ORDER
}
