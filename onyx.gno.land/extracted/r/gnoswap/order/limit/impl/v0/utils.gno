package impl

import (
	"strconv"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/whitelist"
)

func (l *limitOrderImpl) getOrder(orderID uint64) (*plimit.Order, error) {
	value := l.store.GetOrders().Get(plimit.OrderKey(orderID))
	if value == nil {
		return nil, makeErrorWithDetails(errOrderNotFound, strconv.FormatUint(orderID, 10))
	}

	order, ok := value.(*plimit.Order)
	if !ok || order == nil {
		return nil, makeErrorWithDetails(errInvalidState, "invalid stored order")
	}

	return order, nil
}

// validateCreateOrder checks realm policy after NewOrder validates domain terms.
func (l *limitOrderImpl) validateCreateOrder(tokenIn, tokenOut string, makingAmount, expiresAt, now int64) error {
	if tokenIn == "" {
		return makeErrorWithDetails(errInvalidTokenIn, "empty registry key")
	}

	if tokenOut == "" {
		return makeErrorWithDetails(errInvalidTokenOut, "empty registry key")
	}

	if tokenIn == tokenOut {
		return makeErrorWithDetails(errSameToken, tokenIn)
	}

	if err := common.ValidateRegistered(tokenIn); err != nil {
		return makeErrorWithDetails(errInvalidTokenIn, err.Error())
	}

	if err := common.ValidateRegistered(tokenOut); err != nil {
		return makeErrorWithDetails(errInvalidTokenOut, err.Error())
	}

	if !whitelist.HasWhitelistedPool(whitelist.TargetLimit, tokenIn, tokenOut) {
		return makeErrorWithDetails(errPoolNotWhitelisted, tokenIn+":"+tokenOut)
	}

	config := l.store.GetConfig()
	if makingAmount < config.MinMakingAmount() {
		return makeErrorWithDetails(errInvalidMakingAmount, "makingAmount must be >= "+strconv.FormatInt(config.MinMakingAmount(), 10))
	}

	if expiresAt <= now || expiresAt-now < config.MinOrderDuration() {
		return makeErrorWithDetails(errDeadlineTooShort, "order expires before minimum duration")
	}

	if expiresAt-now > config.MaxOrderDuration() {
		return makeErrorWithDetails(errDeadlineTooLong, "order exceeds maximum duration")
	}

	return nil
}

func validateExecution(order *plimit.Order, amountIn, now int64) error {
	if order.RemainingInput() <= 0 {
		return plimit.ErrOrderNotActive
	}

	if order.IsExpired(now) {
		return plimit.ErrOrderExpired
	}

	if amountIn <= 0 || amountIn > order.RemainingInput() {
		return plimit.ErrInvalidFillAmount
	}

	return nil
}
