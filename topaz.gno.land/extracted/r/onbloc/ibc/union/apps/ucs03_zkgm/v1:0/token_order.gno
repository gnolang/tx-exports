package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"

	"gno.land/p/demo/tokens/grc20"
	z "gno.land/p/onbloc/ibc/union/zkgm"
	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/demo/defi/grc20reg"
	core "gno.land/r/onbloc/ibc/union/core"
)

// tagAckSuccess returns a fresh copy of the success ack tag.
func tagAckSuccess() *u256.Uint       { return z.Uint256FromBytes32(z.TAG_ACK_SUCCESS) }
func tagAckFailure() *u256.Uint       { return z.Uint256FromBytes32(z.TAG_ACK_FAILURE) }
func fillTypeProtocol() *u256.Uint    { return z.Uint256FromBytes32(z.FILL_TYPE_PROTOCOL) }
func fillTypeMarketMaker() *u256.Uint { return z.Uint256FromBytes32(z.FILL_TYPE_MARKETMAKER) }

// verifyTokenOrderV2 validates a token order on send: rate-limit, escrow voucher
// or consume native funds, then escrow the channel balance.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L419-L547
func (v *ucs03ZkgmV1) verifyTokenOrderV2(_ int, rlm realm, funds *funds, channelId types.ChannelId, path *u256.Uint, order z.TokenOrderV2) error {
	if path == nil {
		path = u256.Zero()
	}

	switch order.Kind {
	case z.TOKEN_ORDER_KIND_INITIALIZE, z.TOKEN_ORDER_KIND_ESCROW:
		baseDenom := string(order.BaseToken)

		// Verify the metadata decimals match the origin decimals.
		if order.Kind == z.TOKEN_ORDER_KIND_INITIALIZE {
			if err := v.verifyMetadataDecimals(baseDenom, order.Metadata); err != nil {
				return err
			}
		}

		baseTokenLedgerAmount, err := v.ledgerAmountOf(baseDenom, order.BaseAmount)
		if err != nil {
			return err
		}

		// reference verify_token_order_v2 increases the channel balance before
		// escrowing the funds (contract.rs L511-543); rate limiting happens only
		// on the receive/execute side, never here.
		err = v.increaseChannelBalanceV2(0, rlm, channelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)
		if err != nil {
			return err
		}

		err = v.localTokenEscrow(0, rlm, baseDenom, rlm.Previous().Address(), funds, order.BaseAmount)
		if err != nil {
			// rollback the channel balance
			v.decreaseChannelBalanceV2(0, rlm, channelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)

			return err
		}

		return nil
	case z.TOKEN_ORDER_KIND_UNESCROW:
		baseDenom := string(order.BaseToken)

		origin, ok := v.store.GetTokenOrigin(baseDenom)
		if !ok {
			return makeError(errInvalidUnescrow)
		}

		intermediatePath, destChan := z.PopChannelFromPath(origin)

		reversed, err := z.ReverseChannelPath(intermediatePath)
		if err != nil {
			return err
		}

		if path.Cmp(reversed) != 0 {
			return makeError(errInvalidUnescrow)
		}

		if channelId != types.ChannelId(destChan) {
			return makeError(errInvalidUnescrow)
		}

		image, ok := v.store.GetMetadataImageOf(baseDenom)
		if !ok {
			image = [32]byte{}
		}
		// reference predicts against the incoming channel_id (contract.rs L453,
		// L466), not the popped destination channel. The is_sending_back check
		// above guarantees they are equal on the valid-unescrow path.
		wrappedV1 := z.PredictWrappedToken(intermediatePath, uint32(channelId), order.QuoteToken)
		wrappedV2 := z.PredictWrappedTokenV2(intermediatePath, uint32(channelId), order.QuoteToken, image)

		if baseDenom != wrappedV1 && baseDenom != wrappedV2 {
			return makeError(errInvalidUnescrow)
		}

		// UNESCROW base on the valid path is always an ibc/ wrapped voucher (see wrappedV1/V2 check above).
		// Burn it from the sender:
		// supply destruction on the source chain is the correct model for IBC vouchers.
		// GRC20 and native tokens are not valid UNESCROW bases here;
		// they are escrowed via localTokenEscrow on INITIALIZE/ESCROW instead.
		if isIBCTokenDenom(baseDenom) {
			return v.burnVoucher(0, rlm, baseDenom, rlm.Previous().Address(), order.BaseAmount)
		}

		// Defensive fallback for non-ibc denoms: deduct from tx-attached native funds.
		// Valid UNESCROW orders never reach this branch.
		return funds.sub(baseDenom, order.BaseAmount)
	case z.TOKEN_ORDER_KIND_SOLVE:
		return makeError(errSolveNotImplemented)
	default:
		return makeError(errUnknownTokenOrderKind)
	}
}

// executeTokenOrderV2 settles a received token order: mint wrapped vouchers, release escrowed native, or fill from the market maker.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2133-L2306
func (v *ucs03ZkgmV1) executeTokenOrderV2(_ int, rlm realm, packet types.Packet, relayer address, relayerMsg []byte, salt [32]byte, path *u256.Uint, order z.TokenOrderV2, intent bool) (types.RecvPacketResult, error) {
	// Intent packets and explicit solve orders are maker-only.
	if intent || order.Kind == z.TOKEN_ORDER_KIND_SOLVE {
		return v.marketMakerFillV2(0, rlm, relayer, relayerMsg, order)
	}

	if path == nil {
		path = u256.Zero()
	}

	quoteDenom := string(order.QuoteToken)
	baseCovers := order.BaseAmount.Cmp(order.QuoteAmount) >= 0

	// Direct unescrow path: an unwrap whose base covers the quote releases the
	// escrowed native asset to the receiver.
	if order.Kind == z.TOKEN_ORDER_KIND_UNESCROW && baseCovers {
		if err := v.rateLimit(0, rlm, quoteDenom, order.QuoteAmount); err != nil {
			return failureResult(universalErrorAck()), nil
		}

		return v.protocolFillUnescrowV2(0, rlm, packet.DestinationChannelId, path, order.BaseToken, quoteDenom, address(order.Receiver), relayer, order.BaseAmount, order.QuoteAmount)
	}

	destChan, err := tokenOrderDestinationChannel(packet.DestinationChannelId)
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	// Predict the wrapped denom for an escrow/initialize order.
	// A mismatch (or an under-quote) is not an error:
	// the order falls back to a market-maker fill.
	var (
		wrapped     string
		hasWrapped  bool
		image       [32]byte
		meta        z.TokenMetadata
		metaPresent bool
	)

	switch order.Kind {
	case z.TOKEN_ORDER_KIND_ESCROW:
		if img, ok := v.store.GetMetadataImageOf(quoteDenom); ok && !isZeroImage(img) {
			image = img
			wrapped = z.PredictWrappedTokenV2(path, destChan, order.BaseToken, image)
		} else {
			image = [32]byte{}
			wrapped = z.PredictWrappedToken(path, destChan, order.BaseToken)
		}

		hasWrapped = true

		// ESCROW targets an already-deployed wrapped voucher;
		// the deploying first transfer of a token uses INITIALIZE (which carries the metadata).
		// A first-seen ESCROW that matches the predicted wrapped denom has no persisted ledger/scale,
		// so minting would lazily create the voucher at decimals=0 with no origin metadata:
		// an unredeemable orphan whose scale then diverges from a later INITIALIZE's pre-flight check.
		// Reject it as an invalid order so the source refunds, mirroring the INITIALIZE invalid-order handling below.
		if quoteDenom == wrapped && !v.store.HasVoucher(wrapped) {
			return failureResult(universalErrorAck()), nil
		}
	case z.TOKEN_ORDER_KIND_INITIALIZE:
		// gno requires the metadata preimage to initialize a new wrapped token.
		if len(order.Metadata) == 0 {
			return failureResult(universalErrorAck()), nil
		}

		m, derr := z.DecodeTokenMetadata(order.Metadata)
		if derr != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), derr
		}

		meta, metaPresent = m, true
		image = z.MetadataImage(meta)
		wrapped = z.PredictWrappedTokenV2(path, destChan, order.BaseToken, image)
		// A quote token that does not match the deterministic wrapped denom is an
		// invalid initialize order (union InvalidTokenOrderKind).
		if quoteDenom != wrapped {
			return failureResult(universalErrorAck()), nil
		}

		hasWrapped = true
	}

	// Protocol fill when the quote matches the predicted wrapped denom and the base
	// covers the quote; otherwise fall back to a market-maker fill.
	if hasWrapped && quoteDenom == wrapped && baseCovers {
		if err := v.rateLimit(0, rlm, quoteDenom, order.QuoteAmount); err != nil {
			return failureResult(universalErrorAck()), nil
		}

		canDeploy := order.Kind == z.TOKEN_ORDER_KIND_INITIALIZE

		var metadata *z.TokenMetadata
		if metaPresent {
			metadata = &meta
		}

		return v.protocolFillMint(0, rlm, packet.DestinationChannelId, path, order.BaseToken, wrapped, address(order.Receiver), relayer, order.BaseAmount, order.QuoteAmount, metadata, canDeploy)
	}

	return v.marketMakerFillV2(0, rlm, relayer, relayerMsg, order)
}

// protocolFillMint mints the wrapped voucher for an escrow/initialize order:
// quote to the receiver, fee to the relayer, then records deploy-time wrapped
// token metadata. State is written only after the mint succeeds so a recovered
// failure cannot leave orphan origin state.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2309-L2413
func (v *ucs03ZkgmV1) protocolFillMint(_ int, rlm realm, channelId types.ChannelId, path *u256.Uint, baseToken []byte, wrappedToken string, receiver address, relayer address, baseAmount *u256.Uint, quoteAmount *u256.Uint, metadata *z.TokenMetadata, canDeploy bool) (types.RecvPacketResult, error) {
	// fee = base - quote; reject a quote that exceeds base instead of wrapping
	// around to a near-2^256 fee that would only later trip the amount checks.
	fee, underflow := u256.Zero().SubOverflow(baseAmount, quoteAmount)
	if underflow {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), makeError(errTokenOrderFeeUnderflow)
	}

	// A deployable initialize carries the token metadata (name/symbol/decimals);
	// derive its image and reject out-of-range decimals before any mint.
	var image [32]byte

	name, symbol := "", ""

	var (
		decimals uint8

		// Bound-check the amounts against the int64 ledger after downscaling.
		// A deploying initialize derives the scale from the declared decimals,
		// an escrow into an existing voucher from its persisted scale.
		// The mint below re-derives the same scale,
		// so a non-divisible or oversized amount fails gracefully here before any state write.
		scaleExp int
	)

	if canDeploy && metadata != nil {
		image = z.MetadataImage(*metadata)

		ti, err := z.DecodeTokenInitializer(metadata.Initializer)
		if err != nil {
			// Malformed non-empty calldata mirrors an EVM proxy initialization
			// revert. Gno deliberately rejects an empty initializer too instead
			// of creating an uninitialized zero-decimal voucher.
			return failureResult(universalErrorAck()), nil
		}
		if ti.Decimals > grc20.MaxDecimals {
			return failureResult(universalErrorAck()), nil
		}

		name, symbol, decimals = ti.Name, ti.Symbol, ti.Decimals

		scaleExp = scaleExpForDecimals(decimals)
	} else {
		scaleExp = v.scaleExpOf(wrappedToken)
	}

	if _, err := z.ScaleDownToInt64(quoteAmount, scaleExp); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	if _, err := z.ScaleDownToInt64(fee, scaleExp); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	_, hasForeignToken := v.store.GetForeignToken(wrappedToken)
	shouldDeploy := canDeploy && metadata != nil && !hasForeignToken

	var nextPath *u256.Uint

	if shouldDeploy {
		np, err := z.UpdateChannelPath(path, uint32(channelId))
		if err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}

		nextPath = np
	}

	if !quoteAmount.IsZero() {
		if err := v.mintVoucher(0, rlm, wrappedToken, image, name, symbol, decimals, receiver, quoteAmount); err != nil {
			return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
		}
	}

	if !fee.IsZero() {
		if err := v.mintVoucher(0, rlm, wrappedToken, image, name, symbol, decimals, relayer, fee); err != nil {
			panic(execFatal{err.Error()})
		}
	}

	if shouldDeploy {
		v.store.SetForeignToken(0, rlm, wrappedToken, baseToken)
		v.store.SetTokenOrigin(0, rlm, wrappedToken, nextPath)
		v.store.SetMetadataImageOf(0, rlm, wrappedToken, image)
	}

	ack, err := encodeTokenOrderSuccessAck(fillTypeProtocol(), nil)
	if err != nil {
		panic(execFatal{err.Error()})
	}

	return core.NewRecvPacketResult(types.PacketStatusSuccess, ack), nil
}

// protocolFillUnescrowV2 releases an escrowed local asset for an unwrap order:
// decrease the channel balance first, then send the quote to the receiver and
// the fee to the relayer from the proxy escrow.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L2415-L2488
func (v *ucs03ZkgmV1) protocolFillUnescrowV2(_ int, rlm realm, channelId types.ChannelId, path *u256.Uint, baseToken []byte, quoteTokenStr string, receiver address, relayer address, baseAmount *u256.Uint, quoteAmount *u256.Uint) (types.RecvPacketResult, error) {
	reversedPath, err := z.ReverseChannelPath(path)
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	// fee = base - quote; reject a quote that exceeds base instead of wrapping
	// around to a near-2^256 fee that would only later trip amountInt64.
	fee, underflow := u256.Zero().SubOverflow(baseAmount, quoteAmount)
	if underflow {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), makeError(errTokenOrderFeeUnderflow)
	}

	if _, err := v.ledgerAmountOf(quoteTokenStr, quoteAmount); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	if _, err := v.ledgerAmountOf(quoteTokenStr, fee); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	// The released asset is quoteToken, and base/quote/fee share its precision.
	// The channel balance records the vault (ledger) amount, so derive it from
	// base; quote/fee are bound-checked against the int64 ledger (0 for native).
	baseTokenLedgerAmount, err := v.ledgerAmountOf(quoteTokenStr, baseAmount)
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	// reference decreases the escrowed balance before unescrowing (contract.rs
	// L2437-2444); decreaseChannelBalanceV2 rejects an underflow internally. The
	// quote/base tokens are swapped into the balance key as union does (the EVM
	// quoteToken occupies the baseToken slot and vice versa).
	err = v.decreaseChannelBalanceV2(0, rlm, channelId, reversedPath, []byte(quoteTokenStr), baseToken, baseTokenLedgerAmount)
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	if !quoteAmount.IsZero() {
		if err := v.localTokenUnescrow(0, rlm, quoteTokenStr, receiver, quoteAmount); err != nil {
			// rollback the channel balance
			v.increaseChannelBalanceV2(0, rlm, channelId, reversedPath, []byte(quoteTokenStr), baseToken, baseTokenLedgerAmount)

			panic(execFatal{err.Error()})
		}
	}

	if !fee.IsZero() {
		if err := v.localTokenUnescrow(0, rlm, quoteTokenStr, relayer, fee); err != nil {
			// rollback the channel balance
			v.increaseChannelBalanceV2(0, rlm, channelId, reversedPath, []byte(quoteTokenStr), baseToken, baseTokenLedgerAmount)

			panic(execFatal{err.Error()})
		}
	}

	ack, err := encodeTokenOrderSuccessAck(fillTypeProtocol(), nil)
	if err != nil {
		panic(execFatal{err.Error()})
	}

	return core.NewRecvPacketResult(types.PacketStatusSuccess, ack), nil
}

// isZeroImage reports whether a metadata image is the zero value, selecting the V1
// wrapped-token prediction when true.
func isZeroImage(image [32]byte) bool {
	return image == [32]byte{}
}

// encodeTokenOrderSuccessAck builds a success token-order ack with the given fill type.
func encodeTokenOrderSuccessAck(fillType *u256.Uint, marketMaker []byte) ([]byte, error) {
	innerAck, err := z.EncodeTokenOrderAck(z.TokenOrderAck{
		FillType:    fillType,
		MarketMaker: marketMaker,
	})
	if err != nil {
		return nil, err
	}

	return z.EncodeAck(z.Ack{Tag: tagAckSuccess(), InnerAck: innerAck})
}

// marketMakerFillV2 fills a token order from the market maker's voucher balance.
// Native maker funding is intentionally unsupported in v1 because Gno does not
// yet plumb unsafe.OriginSend() funds through recv/intent dispatch. Non-voucher
// quotes therefore return ACK_ERR_ONLY_MAKER; OnIntentRecvPacket turns that into
// an explicit panic so the proven recv path can handle the packet.
//
// TODO(market-maker): add funds plumbing and native quote-token fills in the next
// version, then align this path with Union's LocalTokenMsg handling.
//
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L1791-L1861
func (v *ucs03ZkgmV1) marketMakerFillV2(_ int, rlm realm, relayer address, relayerMsg []byte, order z.TokenOrderV2) (types.RecvPacketResult, error) {
	quoteDenom := string(order.QuoteToken)
	if !v.store.HasVoucher(quoteDenom) {
		// Union can fill local/native quote tokens from the maker's funds. This
		// implementation cannot observe those funds here yet, so only voucher
		// quote tokens are eligible for the market-maker fast path.
		return core.NewRecvPacketResult(types.PacketStatusSuccess, types.CloneBytes(z.ACK_ERR_ONLY_MAKER)), nil
	}

	if _, err := v.ledgerAmountOf(quoteDenom, order.QuoteAmount); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	if err := v.transferVoucher(0, rlm, quoteDenom, relayer, address(order.Receiver), order.QuoteAmount); err != nil {
		return core.NewRecvPacketResult(types.PacketStatusSuccess, types.CloneBytes(z.ACK_ERR_ONLY_MAKER)), nil
	}

	// market_maker is the relayer-supplied settlement target (union saves
	// relayer_msg into MARKET_MAKER); fall back to the relayer's own address when
	// no message was attached.
	marketMaker := relayerMsg
	if len(marketMaker) == 0 {
		marketMaker = []byte(relayer.String())
	}

	ack, err := encodeTokenOrderSuccessAck(fillTypeMarketMaker(), marketMaker)
	if err != nil {
		return core.NewRecvPacketResult(types.PacketStatusUnknown, nil), err
	}

	return core.NewRecvPacketResult(types.PacketStatusSuccess, ack), nil
}

// acknowledgeTokenOrderV2 settles the ack: refund on failure, or release escrow to the market maker on a maker fill.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L974-L1072
func (v *ucs03ZkgmV1) acknowledgeTokenOrderV2(_ int, rlm realm, packet types.Packet, relayer address, salt [32]byte, path *u256.Uint, order z.TokenOrderV2, orderAck z.TokenOrderAck, hasOrderAck bool) error {
	sourceChannelId := packet.SourceChannelId
	if !hasOrderAck {
		return v.refundV2(0, rlm, path, sourceChannelId, order)
	}

	if orderAck.FillType.Eq(fillTypeProtocol()) {
		return nil
	}

	if !orderAck.FillType.Eq(fillTypeMarketMaker()) {
		return makeError(errUnknownFillType)
	}

	marketMaker := address(orderAck.MarketMaker)

	switch order.Kind {
	case z.TOKEN_ORDER_KIND_UNESCROW:
		return v.refundIBCVoucher(0, rlm, order.BaseToken, marketMaker, order.BaseAmount)
	case z.TOKEN_ORDER_KIND_INITIALIZE, z.TOKEN_ORDER_KIND_ESCROW:
		// union: when the maker designates the canonical zero burn address, the
		// escrowed base is burned instead of released to the maker
		// (acknowledge_token_order_v2, contract.rs L1030-1059).
		if marketMaker == z.BURN_ADDRESS {
			return v.burnEscrowedV2(0, rlm, sourceChannelId, path, order)
		}

		return v.settleEscrowedV2(0, rlm, sourceChannelId, path, order, marketMaker)
	default:
		return makeError(errUnsupportedTokenOrderKindForAck)
	}
}

// refundV2 returns a failed or timed-out token order's funds to the sender.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L918-L971
func (v *ucs03ZkgmV1) refundV2(_ int, rlm realm, path *u256.Uint, sourceChannelId types.ChannelId, order z.TokenOrderV2) error {
	switch order.Kind {
	case z.TOKEN_ORDER_KIND_UNESCROW:
		return v.refundIBCVoucher(0, rlm, order.BaseToken, address(order.Sender), order.BaseAmount)
	case z.TOKEN_ORDER_KIND_INITIALIZE, z.TOKEN_ORDER_KIND_ESCROW:
		return v.settleEscrowedV2(0, rlm, sourceChannelId, path, order, address(order.Sender))
	default:
		return makeError(errUnsupportedTokenOrderKindForRefund)
	}
}

// settleEscrowedV2 releases a previously escrowed INITIALIZE/ESCROW BaseAmount to
// recipient: it transfers `ibc/` vouchers from the proxy escrow address and
// releases native tokens from the proxy escrow otherwise. Shared by refundV2 and
// the market-maker fill branch of acknowledgeTokenOrderV2.
func (v *ucs03ZkgmV1) settleEscrowedV2(_ int, rlm realm, sourceChannelId types.ChannelId, path *u256.Uint, order z.TokenOrderV2, recipient address) error {
	// Base is released as the local baseToken; the channel balance records the
	// vault (ledger) amount for that denom (0-scale for native), matching
	// localTokenUnescrow.
	baseDenom := string(order.BaseToken)

	baseTokenLedgerAmount, err := v.ledgerAmountOf(baseDenom, order.BaseAmount)
	if err != nil {
		return err
	}

	// reference decreases the escrowed balance before unescrowing
	// (refund_v2 contract.rs L894-902 / ack L1021-1028);
	// decreaseChannelBalanceV2 rejects an underflow internally.
	err = v.decreaseChannelBalanceV2(0, rlm, sourceChannelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)
	if err != nil {
		return err
	}

	err = v.localTokenUnescrow(0, rlm, baseDenom, recipient, order.BaseAmount)
	if err != nil {
		// rollback the channel balance
		v.increaseChannelBalanceV2(0, rlm, sourceChannelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)

		return err
	}

	return nil
}

// burnEscrowedV2 removes the escrowed channel balance and finalizes the base
// token as burned instead of releasing it to the maker (union burn-address ack).
// Token-type handling:
//   - IBC voucher (ibc/): supply-burned via burnVoucher from proxy escrow.
//   - Native coin: supply cannot be destroyed; coins stay in the proxy banker
//     balance and are tracked in locked-base accounting instead of the
//     channel escrow balance, since burn settlement is a terminal
//     disposition (like release/refund), not an ongoing escrow.
//   - GRC20: same as native — no mint/burn capability over foreign tokens;
//     balance stays at the proxy and is tracked in locked-base accounting.
func (v *ucs03ZkgmV1) burnEscrowedV2(_ int, rlm realm, sourceChannelId types.ChannelId, path *u256.Uint, order z.TokenOrderV2) error {
	// Channel balance records the vault (ledger) amount for the base denom.
	baseDenom := string(order.BaseToken)
	tokenType := getTokenType(baseDenom)

	baseTokenLedgerAmount, err := v.ledgerAmountOf(baseDenom, order.BaseAmount)
	if err != nil {
		return err
	}

	err = v.decreaseChannelBalanceV2(0, rlm, sourceChannelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)
	if err != nil {
		return err
	}

	switch tokenType {
	case IBC_TOKEN:
		if err := v.burnVoucher(0, rlm, baseDenom, rlm.Address(), order.BaseAmount); err != nil {
			// rollback the channel balance
			v.increaseChannelBalanceV2(0, rlm, sourceChannelId, path, order.BaseToken, order.QuoteToken, baseTokenLedgerAmount)

			return err
		}
	case NATIVE_COIN:
		// Supply cannot be destroyed: permanently lock the proxy-held balance and
		// remove it from channel escrow accounting.
		v.store.AddLockedTokenAmount(0, rlm, baseDenom, order.BaseAmount)
	case GRC20_TOKEN:
		// No mint/burn capability over a foreign GRC20: same lock accounting as
		// native.
		v.store.AddLockedTokenAmount(0, rlm, baseDenom, order.BaseAmount)
	}

	return nil
}

// localTokenEscrow takes custody of the base token for a local INITIALIZE/ESCROW
// send. Classification mirrors getTokenType:
//   - IBC voucher: transfer into proxy escrow (no burn on outbound escrow).
//   - GRC20: TransferFrom sender into proxy; requires prior approval.
//   - Native: deduct from tx-attached -send funds held in the funds budget.
func (v *ucs03ZkgmV1) localTokenEscrow(_ int, rlm realm, denom string, sender address, funds *funds, amount *u256.Uint) error {
	switch getTokenType(denom) {
	case IBC_TOKEN:
		return v.transferVoucher(0, rlm, denom, sender, rlm.Address(), amount)
	case GRC20_TOKEN:
		return v.localGRC20Escrow(0, rlm, grc20reg.Get(denom), sender, amount)
	case NATIVE_COIN:
		return funds.sub(denom, amount)
	}

	return nil
}

// localTokenUnescrow releases custody of the base token (recv unwrap / refund /
// settleEscrowedV2). Classification mirrors localTokenEscrow:
//   - IBC voucher: transfer from proxy escrow to recipient (not a mint).
//   - GRC20: Transfer from proxy custody to recipient.
//   - Native: sendNative from the proxy banker balance.
func (v *ucs03ZkgmV1) localTokenUnescrow(_ int, rlm realm, denom string, recipient address, amount *u256.Uint) error {
	switch getTokenType(denom) {
	case IBC_TOKEN:
		return v.transferVoucher(0, rlm, denom, rlm.Address(), recipient, amount)
	case GRC20_TOKEN:
		return v.localGRC20Unescrow(0, rlm, grc20reg.Get(denom), recipient, amount)
	case NATIVE_COIN:
		return v.sendNative(0, rlm, denom, recipient, amount)
	}

	return nil
}

// refundIBCVoucher re-mints an IBC voucher to recipient, preserving the stored metadata image.
func (v *ucs03ZkgmV1) refundIBCVoucher(_ int, rlm realm, baseToken []byte, recipient address, amount *u256.Uint) error {
	baseDenom := string(baseToken)
	image, _ := v.store.GetMetadataImageOf(baseDenom)

	return v.mintVoucher(0, rlm, baseDenom, image, "", "", 0, recipient, amount)
}

// localGRC20Escrow takes custody of a locally-registered grc20 token (not a
// zkgm-issued voucher) for a local send. Unlike native's -send, custody moves
// via TransferFrom, so the sender must have pre-approved this realm.
func (v *ucs03ZkgmV1) localGRC20Escrow(_ int, rlm realm, token *grc20.Token, sender address, amount *u256.Uint) error {
	n, err := amountInt64(amount)
	if err != nil {
		return err
	}

	teller := token.RealmTeller(0, rlm)

	beforeBalance := teller.BalanceOf(rlm.Address())

	err = teller.TransferFrom(0, rlm, sender, rlm.Address(), n)
	if err != nil {
		return err
	}

	afterBalance := teller.BalanceOf(rlm.Address())

	if afterBalance-beforeBalance != n {
		return makeError(errInvalidTokenOrderTransferAmount)
	}

	return nil
}

// localGRC20Unescrow releases a locally-registered grc20 token from proxy
// custody (recv unwrap / refund), mirroring localGRC20Escrow.
func (v *ucs03ZkgmV1) localGRC20Unescrow(_ int, rlm realm, token *grc20.Token, recipient address, amount *u256.Uint) error {
	n, err := amountInt64(amount)
	if err != nil {
		return err
	}

	teller := token.RealmTeller(0, rlm)

	beforeBalance := teller.BalanceOf(rlm.Address())

	err = teller.Transfer(0, rlm, recipient, n)
	if err != nil {
		return err
	}

	afterBalance := teller.BalanceOf(rlm.Address())

	if beforeBalance-afterBalance != n {
		return makeError(errInvalidTokenOrderTransferAmount)
	}

	return nil
}

// verifyMetadataDecimals rejects an INITIALIZE order whose declared metadata
// decimals do not match the locally-known ground truth for baseDenom: a
// registered grc20's real decimals, or a held voucher's recorded
// OriginDecimals when forwarding it onward. baseDenom that is native (or
// otherwise unknown here) is out of scope for this check. Left unchecked, a
// wrong declaration would still move the correct raw amount here but cause
// the counterparty (or next hop) to deploy/interpret the wrapped copy at the
// wrong precision.
func (v *ucs03ZkgmV1) verifyMetadataDecimals(baseDenom string, metadata []byte) error {
	var originDecimals uint8

	if token := grc20reg.Get(baseDenom); token != nil {
		originDecimals = uint8(token.GetDecimals())
	} else if vou, ok := v.store.GetVoucher(baseDenom); ok {
		originDecimals = vou.OriginDecimals()
	} else {
		return nil
	}

	meta, err := z.DecodeTokenMetadata(metadata)
	if err != nil {
		return err
	}

	ti, err := z.DecodeTokenInitializer(meta.Initializer)
	if err != nil {
		return err
	}

	if ti.Decimals != originDecimals {
		return makeError(errMetadataDecimalsMismatch)
	}

	return nil
}
