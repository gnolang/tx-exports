package impl

import (
	"time"

	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	"gno.land/p/gnoswap/utils/v1"
	rotree "gno.land/p/nt/bptree/rotree/v0"
	"gno.land/p/onbloc/json/v0"

	"gno.land/r/gnoswap/order/halt"
	"gno.land/r/gnoswap/order/whitelist"
)

// Getters return copies of stored orders, groups, and configs.
// A stored pointer must never leave the realm: methods of pdca types run
// with the storing realm's authority, so a caller holding the pointer
// could mutate state through its setters.
// Store trees are wrapped in read-only views for the same reason:
// views of trees holding pointers copy every entry they return.
// Group copies leave out the round marks, so their cost does not grow with
// the marks any order creator can add; GetGroupRoundMarks reads them.

// GetConfig returns a copy of the configuration.
func (d *dcaOrderImpl) GetConfig() *pdca.Config {
	return d.store.GetConfig().Clone()
}

// GetNextOrderID returns the ID the next created order receives.
func (d *dcaOrderImpl) GetNextOrderID() uint64 {
	return d.store.GetNextOrderID()
}

// ExistsOrder reports whether orderID is an active order.
func (d *dcaOrderImpl) ExistsOrder(orderID uint64) bool {
	return d.store.GetOrders().Has(pdca.OrderKey(orderID))
}

// GetOrder returns a copy of an active order.
func (d *dcaOrderImpl) GetOrder(orderID uint64) (*pdca.Order, error) {
	order, err := d.getOrder(orderID)
	if err != nil {
		return nil, err
	}

	return order.Clone(), nil
}

// GetOrders returns a read-only view of active orders keyed by OrderKey.
func (d *dcaOrderImpl) GetOrders() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetOrders(), cloneOrderEntry)
}

// GetOrdersByOwner returns the read-only OwnerOrderKey -> orderID index.
func (d *dcaOrderImpl) GetOrdersByOwner() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetOrdersByOwner(), nil)
}

// GetClaimableAmount returns what the next Claim of an active order pays.
func (d *dcaOrderImpl) GetClaimableAmount(orderID uint64) int64 {
	order, group, err := d.getOrderWithGroup(orderID)
	if err != nil {
		return 0
	}

	claimableAmount, err := calculateClaimableAmount(order, group)
	if err != nil {
		panic(err.Error())
	}

	return claimableAmount
}

// GetOrderIDsByOwner pages an owner's active order IDs.
func (d *dcaOrderImpl) GetOrderIDsByOwner(owner address, startAfterID uint64, count int) []uint64 {
	if count <= 0 {
		return []uint64{}
	}

	prefix := pdca.OwnerOrderPrefix(owner)
	start := prefix

	if startAfterID > 0 {
		if startAfterID == ^uint64(0) {
			return []uint64{}
		}

		start = pdca.OwnerOrderKey(owner, gnsmath.SafeAddUint64(startAfterID, 1))
	}

	orderIDs := []uint64{}

	d.store.GetOrdersByOwner().Iterate(start, pdca.PrefixEnd(prefix), func(_ string, value any) bool {
		orderIDs = append(orderIDs, value.(uint64))

		return len(orderIDs) >= count
	})

	return orderIDs
}

// GetOrderIDsByGroup pages a group's active order IDs.
func (d *dcaOrderImpl) GetOrderIDsByGroup(groupID string, startAfterID uint64, count int) []uint64 {
	if count <= 0 {
		return []uint64{}
	}

	orderIDs, _ := d.getGroupOrderIDs(groupID, startAfterID, count)

	return orderIDs
}

// ExistsGroup reports whether groupID is a stored group.
func (d *dcaOrderImpl) ExistsGroup(groupID string) bool {
	return d.store.GetGroups().Has(groupID)
}

// GetGroup returns a copy of a group without its round marks.
func (d *dcaOrderImpl) GetGroup(groupID string) (*pdca.Group, error) {
	group, err := d.getGroup(groupID)
	if err != nil {
		return nil, err
	}

	return group.CloneWithoutRoundMarks(), nil
}

// GetGroups returns a read-only view of groups keyed by group ID.
func (d *dcaOrderImpl) GetGroups() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetGroups(), cloneGroupEntry)
}

// GetGroupRoundMarks returns a read-only view of a group's round marks
// keyed by RoundKey, or nil if the group does not exist.
func (d *dcaOrderImpl) GetGroupRoundMarks(groupID string) *rotree.ReadOnlyTree {
	group, err := d.getGroup(groupID)
	if err != nil {
		return nil
	}

	return group.RoundMarks()
}

// GetOrdersByGroup returns the read-only GroupOrderKey -> orderID index.
func (d *dcaOrderImpl) GetOrdersByGroup() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetOrdersByGroup(), nil)
}

// GetOrderAmountsByGroup returns the read-only
// GroupOrderAmountKey -> endRound index.
func (d *dcaOrderImpl) GetOrderAmountsByGroup() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetOrderAmountsByGroup(), nil)
}

// GetScheduledGroups returns the read-only ScheduleKey -> groupID index.
func (d *dcaOrderImpl) GetScheduledGroups() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetScheduledGroups(), nil)
}

// GetTokenMinAmountPerExecution returns the minimum input per execution set
// for tokenPath, or 0 if none is set.
func (d *dcaOrderImpl) GetTokenMinAmountPerExecution(tokenPath string) int64 {
	return getTokenMinAmountPerExecution(d.store, tokenPath)
}

// GetMinAmountPerExecution returns the minimum input per execution a new order
// selling tokenPath needs: the larger of the global and the token minimum.
func (d *dcaOrderImpl) GetMinAmountPerExecution(tokenPath string) int64 {
	return d.minAmountPerExecution(tokenPath)
}

// GetTokenMinAmountsPerExecution returns the read-only tokenPath -> int64
// index of per-token minimums.
func (d *dcaOrderImpl) GetTokenMinAmountsPerExecution() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetTokenMinAmountsPerExecution(), nil)
}

// GetPairPriceLimit returns a copy of the price limit of selling inputToken
// for outputToken, and whether one is set.
func (d *dcaOrderImpl) GetPairPriceLimit(inputToken string, outputToken string) (*pdca.PairPriceLimit, bool) {
	limit := getPairPriceLimit(d.store.GetPairPriceLimits(), inputToken, outputToken)
	if limit == nil {
		return nil, false
	}

	return limit.Clone(), true
}

// GetPairPriceLimits returns a read-only view of the pair price limits keyed
// by PairKey.
func (d *dcaOrderImpl) GetPairPriceLimits() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetPairPriceLimits(), clonePairPriceLimitEntry)
}

// GetExecutableGroups lists copies of due groups after the cursor entry.
// The schedule index is ordered by next execution timestamp,
// so the scan stops at the first group that is not yet due.
// Pools are not quoted; a listed round may still revert.
// Nothing is listed while rounds are halted.
func (d *dcaOrderImpl) GetExecutableGroups(cursor string, count int) ([]*pdca.Group, error) {
	if count <= 0 {
		return []*pdca.Group{}, nil
	}

	start, err := pdca.ParseScheduleCursor(cursor)
	if err != nil {
		return nil, makeErrorWithDetails(errInvalidCursor, cursor)
	}

	// Rounds cannot run while execution is halted.
	if isExecutionHalted() {
		return []*pdca.Group{}, nil
	}

	currentTimestamp := time.Now().Unix()
	groupIDs := []string{}
	d.store.GetScheduledGroups().Iterate(start, "", func(key string, value any) bool {
		if key == start && start != "" {
			return false
		}

		if pdca.ScheduleKeyTimestamp(key) > currentTimestamp {
			return true
		}

		groupIDs = append(groupIDs, value.(string))

		return len(groupIDs) >= count
	})

	groups := make([]*pdca.Group, 0, len(groupIDs))
	for _, groupID := range groupIDs {
		group, err := d.GetGroup(groupID)
		if err != nil {
			return nil, err
		}

		groups = append(groups, group)
	}

	return groups, nil
}

// GetOrderExecutionLogs returns copies of up to count of an order's unreleased
// execution logs, oldest first.
func (d *dcaOrderImpl) GetOrderExecutionLogs(orderID uint64, count int) ([]*pdca.ExecutionLog, error) {
	order, err := d.getOrder(orderID)
	if err != nil {
		return nil, err
	}

	return pdca.ExecutionLogs(d.store.GetExecutionLogs(), order, count), nil
}

// GetExecutionLogs returns the read-only ExecutionLogKey -> lastRound index
// of unreleased execution logs.
func (d *dcaOrderImpl) GetExecutionLogs() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetExecutionLogs(), nil)
}

// GetPendingExecutionFeeAmount returns the execution fee of tokenPath
// held by this realm until the protocol fee realm accepts it.
func (d *dcaOrderImpl) GetPendingExecutionFeeAmount(tokenPath string) int64 {
	return getPendingExecutionFeeAmount(d.store.GetPendingExecutionFees(), tokenPath)
}

// GetPendingExecutionFees returns the read-only tokenPath -> amount index
// of execution fees held until the protocol fee realm accepts them.
func (d *dcaOrderImpl) GetPendingExecutionFees() *rotree.ReadOnlyTree {
	return rotree.Wrap(d.store.GetPendingExecutionFees(), nil)
}

// GetExecutionQuote reports how the group's next round would trade now.
// Every pool is quoted here, even a single one,
// so the selection and output match ExecuteGroup in the same block.
func (d *dcaOrderImpl) GetExecutionQuote(groupID string) string {
	group, err := d.getGroup(groupID)
	if err != nil {
		return ""
	}

	config := d.store.GetConfig()
	amountIn := group.OrderAmount()
	selectedPoolPath := ""
	expectedAmountOut := int64(0)
	expectedExecutionFeeAmount := int64(0)
	expectedMinOrderAmountOut := int64(0)
	candidateNodes := []*json.Node{}
	minAmountNodes := []*json.Node{}

	// The round checks the smallest order of each execution fee rate after
	// that rate. The quote's fee and order output assume the highest rate of
	// the orders the round sells, the most any of them pays.
	minAmounts := []feeRateMinAmount{}
	if amountIn > 0 {
		minAmounts = d.getFeeRateMinAmounts(group, group.Round()+1, false)
	}

	minAmountPerExecution := minAmountPerExecutionOf(minAmounts)
	executionFeeRate := maxExecutionFeeRateOf(minAmounts)

	priceLimit := getPairPriceLimit(d.store.GetPairPriceLimits(), group.InputToken(), group.OutputToken())
	minOutputPerInputX128 := "0"
	priceLimitUpdatedAt := int64(0)

	if priceLimit != nil {
		minOutputPerInputX128 = priceLimit.MinOutputPerInputX128().ToString()
		priceLimitUpdatedAt = priceLimit.UpdatedAt()
	}

	if amountIn > 0 {
		selectedPool, candidates := selectPool(whitelist.GetWhitelistedPools(whitelist.TargetDCA), priceLimit, config.MaxPoolPriceDeviationRate(), config.MaxPairPriceLimitAge(), group.InputToken(), group.OutputToken(), amountIn, true)
		if selectedPool != nil {
			expectedAmountOut = selectedPool.quotedAmountOut
			selectedPoolPath = selectedPool.poolPath

			expectedOrderAmountOut, err := pdca.CalculateMinNetAmountOut(expectedAmountOut, executionFeeRate)
			if err != nil {
				panic(err.Error())
			}

			expectedExecutionFeeAmount = expectedAmountOut - expectedOrderAmountOut
		}

		// The least output the round's per-order check would compare with
		// max(1, minOrderAmountOut).
		outputPerAmountX128, err := pdca.CalculateOutputPerAmountX128(expectedAmountOut, amountIn)
		if err != nil {
			panic(err.Error())
		}

		for i, minAmount := range minAmounts {
			orderAmountOut, err := calculateMinOrderAmountOut(minAmount, outputPerAmountX128)
			if err != nil {
				panic(err.Error())
			}

			if i == 0 || orderAmountOut < expectedMinOrderAmountOut {
				expectedMinOrderAmountOut = orderAmountOut
			}

			minAmountNodes = append(minAmountNodes, json.ObjectNode("", map[string]*json.Node{
				"executionFeeRate":      intNode(minAmount.executionFeeRate),
				"minAmountPerExecution": intNode(minAmount.minAmountPerExecution),
			}))
		}

		for _, candidate := range candidates {
			candidateAmountOut := int64(0)
			if candidate.isQuoted {
				candidateAmountOut = candidate.quotedAmountOut
			}

			candidateNodes = append(candidateNodes, json.ObjectNode("", map[string]*json.Node{
				"poolPath":         json.StringNode("", candidate.poolPath),
				"eligible":         json.BoolNode("", candidate.isEligible()),
				"ineligibleCode":   json.StringNode("", candidate.ineligibleCode),
				"ineligibleReason": json.StringNode("", candidate.ineligibleReason),
				"amountOut":        intNode(candidateAmountOut),
			}))
		}
	}

	return marshal(map[string]*json.Node{
		"groupId":                      json.StringNode("", group.ID()),
		"inputToken":                   json.StringNode("", group.InputToken()),
		"outputToken":                  json.StringNode("", group.OutputToken()),
		"amountIn":                     intNode(amountIn),
		"minAmountPerExecution":        intNode(minAmountPerExecution),
		"executable":                   json.BoolNode("", isGroupExecutable(group, time.Now().Unix())),
		"selectedPool":                 json.StringNode("", selectedPoolPath),
		"expectedAmountOut":            intNode(expectedAmountOut),
		"executionFeeRate":             intNode(executionFeeRate),
		"expectedExecutionFeeAmount":   intNode(expectedExecutionFeeAmount),
		"expectedOrderAmountOut":       intNode(expectedAmountOut - expectedExecutionFeeAmount),
		"expectedMinOrderAmountOut":    intNode(expectedMinOrderAmountOut),
		"minAmountsByExecutionFeeRate": json.ArrayNode("", minAmountNodes),
		"minOutputPerInputX128":        json.StringNode("", minOutputPerInputX128),
		"priceLimitUpdatedAt":          intNode(priceLimitUpdatedAt),
		"candidates":                   json.ArrayNode("", candidateNodes),
	})
}

// calculateClaimableAmount returns what the next Claim pays the owner,
// net of the order's execution fee.
func calculateClaimableAmount(order *pdca.Order, group *pdca.Group) (int64, error) {
	endAccumulatedX128, _, err := getOrderEndAccumulatedOutputPerAmountX128(order, group)
	if err != nil {
		return 0, err
	}

	payout, err := calculateOrderPayout(order, endAccumulatedX128)
	if err != nil {
		return 0, err
	}

	return payout.claimedAmount, nil
}

// isGroupExecutable reports whether the schedule and the halts allow
// the group's next round now.
// Pools are not quoted here.
func isGroupExecutable(group *pdca.Group, currentTimestamp int64) bool {
	return group.OrderAmount() > 0 && currentTimestamp >= group.NextExecutionTimestamp() && !isExecutionHalted()
}

// isExecutionHalted reports whether execute or withdraw is halted,
// matching the checks ExecuteGroup makes before running a round.
func isExecutionHalted() bool {
	_, halted := haltedOperation(halt.OperationExecute, halt.OperationWithdraw)
	return halted
}

func marshal(fields map[string]*json.Node) string {
	b, err := json.Marshal(json.ObjectNode("", fields))
	if err != nil {
		panic(err.Error())
	}

	return string(b)
}

func intNode(v int64) *json.Node {
	return json.StringNode("", utils.FormatInt(v))
}

func cloneOrderEntry(value any) any {
	order, ok := value.(*pdca.Order)
	if !ok {
		return nil
	}

	return order.Clone()
}

func cloneGroupEntry(value any) any {
	group, ok := value.(*pdca.Group)
	if !ok {
		return nil
	}

	return group.CloneWithoutRoundMarks()
}

func clonePairPriceLimitEntry(value any) any {
	limit, ok := value.(*pdca.PairPriceLimit)
	if !ok {
		return nil
	}

	return limit.Clone()
}
