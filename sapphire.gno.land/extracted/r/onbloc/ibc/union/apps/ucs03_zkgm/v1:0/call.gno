package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"

	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	core "gno.land/r/onbloc/ibc/union/core"
)

// verifyCall rejects eureka mode and requires the call sender to match the dispatch sender.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2997-L3019
func (v *ucs03ZkgmV1) verifyCall(_ int, rlm realm, call z.Call) error {
	if call.Eureka {
		return makeError(errEurekaUnsupported)
	}

	if string(call.Sender) != rlm.Previous().Address().String() {
		return makeError(errInvalidCallSender)
	}

	return nil
}

// executeCall dispatches an OP_CALL to the registered receiver's OnZkgm callback; failures and panics fail closed.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L1500-L1683
func (v *ucs03ZkgmV1) executeCall(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte, path *u256.Uint, call z.Call, intent bool) (types.RecvPacketResult, error) {
	// TODO: when eureka is supported, fail it closed on intent (return
	// ACK_ERR_ONLY_MAKER) like every other opcode instead of a failure ack.
	if call.Eureka {
		return callErrAck(0, rlm, makeError(errEurekaUnsupported)), nil
	}

	sender := types.CloneBytes(call.Sender)
	calldata := types.CloneBytes(call.ContractCalldata)
	receiverPath := string(call.ContractAddress)
	receiver, ok := v.store.GetReceiver(receiverPath)

	if !ok || receiver == nil {
		return callErrAck(0, rlm, makeError(errReceiverNotRegistered, receiverPath)), nil
	}

	relayerStr := string(relayer)
	proxyAccount := z.PredictCallProxyAccount(path, packet.DestinationChannelId, sender)

	// Intent settlement dispatches OnIntentZkgm to the receiver (union execute_call
	// intent arm), and is maker-only: any receiver failure reverts to ACK_ERR_ONLY_MAKER
	// so the proven recv can settle instead.
	if intent {
		env := z.IntentCallEnv{
			Caller:             relayerStr,
			ProxyAccount:       proxyAccount,
			Path:               path,
			SourceChannel:      packet.SourceChannelId.String(),
			DestinationChannel: packet.DestinationChannelId.String(),
			Sender:             sender,
			Calldata:           calldata,
			MarketMaker:        []byte(relayerStr),
			MarketMakerMsg:     types.CloneBytes(relayerMsg),
		}
		if err, panicked := safeCallOnIntentZkgm(0, rlm, receiver, env); panicked || err != nil {
			return core.NewRecvPacketResult(types.PacketStatusSuccess, types.CloneBytes(z.ACK_ERR_ONLY_MAKER)), nil
		}

		return callSuccessAck()
	}

	env := z.CallEnv{
		Caller:             relayerStr,
		ProxyAccount:       proxyAccount,
		Path:               path,
		SourceChannel:      packet.SourceChannelId.String(),
		DestinationChannel: packet.DestinationChannelId.String(),
		Sender:             sender,
		Calldata:           calldata,
		Relayer:            []byte(relayerStr),
		RelayerMsg:         types.CloneBytes(relayerMsg),
	}

	err, panicked := safeCallOnZkgm(0, rlm, receiver, env)
	if panicked {
		return core.NewRecvPacketResult(types.PacketStatusSuccess, types.CloneBytes(z.ACK_ERR_ONLY_MAKER)), nil
	}

	if err != nil {
		return callErrAck(0, rlm, err), nil
	}

	return callSuccessAck()
}

// callSuccessAck builds the empty success acknowledgement a completed call writes.
func callSuccessAck() (types.RecvPacketResult, error) {
	ack, err := z.EncodeAck(z.Ack{Tag: tagAckSuccess(), InnerAck: []byte{}})
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	return core.NewRecvPacketResult(types.PacketStatusSuccess, ack), nil
}

// acknowledgeCall is a no-op for standard calls; eureka mode is unsupported.
func (v *ucs03ZkgmV1) acknowledgeCall(_ int, rlm realm, packet types.Packet, path *u256.Uint, call z.Call) error {
	if call.Eureka {
		return makeError(errEurekaUnsupported)
	}

	return nil
}

// timeoutCall is a no-op for standard calls; eureka mode is unsupported.
func (v *ucs03ZkgmV1) timeoutCall(_ int, rlm realm, packet types.Packet, path *u256.Uint, call z.Call) error {
	if call.Eureka {
		return makeError(errEurekaUnsupported)
	}

	return nil
}

// safeCallOnZkgm runs the receiver and reports a failure as panicked=true.
//
// Only works in test builds: revive() requires MachineOptions.ReviveEnabled,
// which gnovm sets only in gnovm/pkg/test, never on-chain. The recover()
// fallback can't substitute for it either — a panic crossing the cross(rlm)
// boundary skips ordinary ancestor defers on-chain. So a panicking receiver
// reverts the whole recv transaction in production, matching Union's own
// CosmWasm dispatch (not its EVM one, which isolates receiver reverts via a
// low-level self call Gno has no on-chain equivalent for). The security/
// intent/batch scenario filetests exercise the test-only path; on a real
// chain they'd still revert atomically, just via the raw panic.
func safeCallOnZkgm(_ int, rlm realm, receiver z.Zkgmable, env z.CallEnv) (err error, panicked bool) {
	if canRevive() {
		p := revive(func() {
			err = receiver.OnZkgm(cross(rlm), env)
		})

		return err, p != nil
	}

	defer func() {
		if recover() != nil {
			err = nil
			panicked = true
		}
	}()

	err = receiver.OnZkgm(cross(rlm), env)

	return err, false
}

// safeCallOnIntentZkgm runs the receiver's intent callback and reports a failure
// as panicked=true, mirroring safeCallOnZkgm for the OnIntentZkgm path.
func safeCallOnIntentZkgm(_ int, rlm realm, receiver z.Zkgmable, env z.IntentCallEnv) (err error, panicked bool) {
	if canRevive() {
		p := revive(func() {
			err = receiver.OnIntentZkgm(cross(rlm), env)
		})

		return err, p != nil
	}

	defer func() {
		if recover() != nil {
			err = nil
			panicked = true
		}
	}()

	err = receiver.OnIntentZkgm(cross(rlm), env)

	return err, false
}

// canRevive reports whether revive works in the current runtime. revive panics
// rather than returning when the interpreter lacks support for it.
func canRevive() (ok bool) {
	ok = true

	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	revive(func() {})

	return ok
}

// callErrAck encodes err as a failure acknowledgement for the call.
func callErrAck(_ int, rlm realm, err error) types.RecvPacketResult {
	ack, encErr := z.EncodeAck(z.Ack{Tag: tagAckFailure(), InnerAck: []byte(err.Error())})
	if encErr != nil {
		// EncodeAck on a 2-field schema is essentially infallible. A failure
		// would emit a non-Tag-prefixed ack the counterparty can't decode.
		panic(encErr)
	}

	return failureResult(ack)
}
