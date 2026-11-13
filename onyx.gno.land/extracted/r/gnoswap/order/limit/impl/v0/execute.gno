package impl

import (
	"strconv"
	"time"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	lo "gno.land/r/gnoswap/order/limit"
	"gno.land/r/gnoswap/order/whitelist"
	"gno.land/r/gnoswap/pool"
)

// ExecuteOrder returns actual input and pool output before the order fee,
// allowing the pool to stop before maxAmountIn at a nonzero price limit.
func (l *limitOrderImpl) ExecuteOrder(_ int, rlm realm, orderID uint64, maxAmountIn int64, poolFee uint32, sqrtPriceLimitX96 string) (int64, int64) {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(halt.OperationExecute, halt.OperationWithdraw)
	assertIsAuthorizedKeeper(rlm.PkgPath(), prev.Address())

	order, err := l.getOrder(orderID)
	if err != nil {
		panic(err.Error())
	}

	result, err := l.executeOrder(0, rlm, order, maxAmountIn, poolFee, sqrtPriceLimitX96)
	if err != nil {
		panic(realmError(err).Error())
	}

	emitOrderExecution(prev.Address(), prev.PkgPath(), order, poolFee, result)

	return result.actualInput, result.poolOutput
}

func emitOrderExecution(prevAddr address, prevRealm string, order *plimit.Order, poolFee uint32, result orderExecutionResult) {
	route := order.TokenIn() + ":" + order.TokenOut() + ":" + strconv.FormatUint(uint64(poolFee), 10)
	emitOrderFilled(prevAddr, prevRealm, order, route, result.actualInput, result.poolOutput, result.executionFeeAmount)

	if result.executionFeeAmount > 0 || result.forwardedExecutionFeeAmount > 0 || result.pendingExecutionFeeAmount > 0 {
		emitExecutionFeeCollected(
			prevAddr,
			prevRealm,
			order.ID(),
			order.TokenOut(),
			result.executionFeeAmount,
			result.forwardedExecutionFeeAmount,
			result.pendingExecutionFeeAmount,
		)
	}

	if order.RemainingInput() == 0 {
		emitOrderCompleted(prevAddr, prevRealm, order)
	}
}

type orderExecutionResult struct {
	actualInput                 int64
	poolOutput                  int64
	executionFeeAmount          int64
	forwardedExecutionFeeAmount int64
	pendingExecutionFeeAmount   int64
}

func (l *limitOrderImpl) executeOrder(_ int, rlm realm, order *plimit.Order, maxAmountIn int64, poolFee uint32, sqrtPriceLimitX96 string) (orderExecutionResult, error) {
	now := time.Now().Unix()
	if err := validateExecution(order, maxAmountIn, now); err != nil {
		return orderExecutionResult{}, err
	}

	poolPath := pool.GetPoolPath(order.TokenIn(), order.TokenOut(), poolFee)
	if !whitelist.IsWhitelistedPool(whitelist.TargetLimit, poolPath) {
		return orderExecutionResult{}, makeErrorWithDetails(errPoolNotWhitelisted, poolPath)
	}

	zeroForOne := order.TokenIn() < order.TokenOut()

	limit, fullInput, err := orderPriceLimit(sqrtPriceLimitX96, zeroForOne)
	if err != nil {
		return orderExecutionResult{}, err
	}

	token0, token1 := order.TokenIn(), order.TokenOut()
	if !zeroForOne {
		token0, token1 = token1, token0
	}

	custody := lo.Address()
	inputBefore := common.BalanceOf(order.TokenIn(), custody)
	outputBefore := common.BalanceOf(order.TokenOut(), custody)
	callback := lo.NewSwapCallback(0, rlm, order.TokenIn(), zeroForOne, maxAmountIn)
	amount0, amount1 := pool.Swap(
		cross(rlm), token0, token1, poolFee, custody, zeroForOne,
		strconv.FormatInt(maxAmountIn, 10), limit, callback,
	)

	actualInput, poolOutput, err := poolSwapAmounts(amount0, amount1, zeroForOne)
	if err != nil {
		return orderExecutionResult{}, err
	}

	if actualInput > maxAmountIn || (fullInput && actualInput != maxAmountIn) {
		return orderExecutionResult{}, plimit.ErrInvalidFillAmount
	}

	return l.settleOrderFill(0, rlm, order, actualInput, poolOutput, inputBefore, outputBefore, now)
}

func (l *limitOrderImpl) settleOrderFill(_ int, rlm realm, order *plimit.Order, actualInput, poolOutput, inputBefore, outputBefore, now int64) (orderExecutionResult, error) {
	custody := lo.Address()

	inputAfter := common.BalanceOf(order.TokenIn(), custody)
	outputAfter := common.BalanceOf(order.TokenOut(), custody)

	if inputBefore < 0 || inputAfter < 0 || inputAfter > inputBefore || inputBefore-inputAfter != actualInput {
		return orderExecutionResult{}, plimit.ErrInvalidFillAmount
	}

	if outputBefore < 0 || outputAfter < outputBefore || outputAfter-outputBefore != poolOutput {
		return orderExecutionResult{}, plimit.ErrInsufficientOutput
	}

	executionFeeBefore := order.ExecutionFee()
	if err := order.ApplyFill(actualInput, poolOutput, now); err != nil {
		return orderExecutionResult{}, err
	}

	executionFeeAmount := order.ExecutionFee() - executionFeeBefore
	userOutput := poolOutput - executionFeeAmount

	if order.RemainingInput() == 0 {
		l.removeOrder(order)
	}

	// Finalize order state before paying the owner or collecting the execution fee.
	if userOutput > 0 {
		common.SafeGRC20Transfer(0, rlm, order.TokenOut(), order.Owner(), userOutput)
	}

	forwardedExecutionFeeAmount, pendingExecutionFeeAmount := l.collectExecutionFee(0, rlm, order.TokenOut(), executionFeeAmount)

	return orderExecutionResult{
		actualInput:                 actualInput,
		poolOutput:                  poolOutput,
		executionFeeAmount:          executionFeeAmount,
		forwardedExecutionFeeAmount: forwardedExecutionFeeAmount,
		pendingExecutionFeeAmount:   pendingExecutionFeeAmount,
	}, nil
}
