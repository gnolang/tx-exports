package admin

import (
	"testing"

	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/nt/uassert/v0"
)

const (
	testFaucetFundAmount int64 = 1000000
)

type faucetTestHelper struct{}

var faucetTest = &faucetTestHelper{}

func TestSetFaucetTargetAmount(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		amount       int64
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin sets target amount", testAdmin, testing.NewUserRealm(testAdmin), 1000000, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), 1000000, true, "admin access required"},
		{"zero amount", testAdmin, testing.NewUserRealm(testAdmin), 0, true, "faucet target amount must be positive"},
		{"negative amount", testAdmin, testing.NewUserRealm(testAdmin), -1, true, "faucet target amount must be positive"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				SetFaucetTargetAmount(cross(cur), tt.amount)
			})
			uassert.Equal(t, int64(0), GetFaucetTargetAmount())
			continue
		}

		SetFaucetTargetAmount(cross(cur), tt.amount)
		uassert.Equal(t, tt.amount, GetFaucetTargetAmount())
	}
}

func TestRequestFaucetTransfersDeficit(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	adminRealm := adminRealmAddr()
	adminBefore := adminUgnotBalance(adminRealm)
	operatorBefore := adminUgnotBalance(testOperator)
	expectedTransfer := int64(300000)
	faucetTest.FundAdmin(testFaucetFundAmount)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetOperator(cross(cur), testOperator)
	SetFaucetTargetAmount(cross(cur), operatorBefore+expectedTransfer)

	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	transferred := RequestFaucet(cross(cur))

	uassert.Equal(t, expectedTransfer, transferred)
	uassert.Equal(t, operatorBefore+expectedTransfer, adminUgnotBalance(testOperator))
	uassert.Equal(t, adminBefore+testFaucetFundAmount-expectedTransfer, adminUgnotBalance(adminRealm))
}

func TestRequestFaucetForTransfersDeficit(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	adminRealm := adminRealmAddr()
	adminBefore := adminUgnotBalance(adminRealm)
	operatorBefore := adminUgnotBalance(testOperator)
	expectedTransfer := int64(300000)
	faucetTest.FundAdmin(testFaucetFundAmount)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetOperator(cross(cur), testOperator)
	SetFaucetTargetAmount(cross(cur), operatorBefore+expectedTransfer)
	transferred := RequestFaucetFor(cross(cur), testOperator)

	uassert.Equal(t, expectedTransfer, transferred)
	uassert.Equal(t, operatorBefore+expectedTransfer, adminUgnotBalance(testOperator))
	uassert.Equal(t, adminBefore+testFaucetFundAmount-expectedTransfer, adminUgnotBalance(adminRealm))
}

func TestRequestFaucetsTransfersDeficits(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	UnsetOperator(cross(cur), testAdmin)
	SetOperator(cross(cur), testOperator)
	SetOperator(cross(cur), testUser)
	SetOperator(cross(cur), testUser2)

	adminRealm := adminRealmAddr()
	adminBefore := adminUgnotBalance(adminRealm)
	operatorBefore := adminUgnotBalance(testOperator)
	userBefore := adminUgnotBalance(testUser)
	user2Before := adminUgnotBalance(testUser2)
	targetAmount := maxInt64(operatorBefore, maxInt64(userBefore, user2Before)) + 300000
	if user2Before < targetAmount {
		faucetTest.Issue(testUser2, targetAmount-user2Before)
		user2Before = targetAmount
	}
	operatorDeficit := targetAmount - operatorBefore
	userDeficit := targetAmount - userBefore
	expectedTransfer := operatorDeficit + userDeficit
	faucetTest.FundAdmin(expectedTransfer)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFaucetTargetAmount(cross(cur), targetAmount)
	transferred := RequestFaucets(cross(cur))

	uassert.Equal(t, expectedTransfer, transferred)
	uassert.Equal(t, targetAmount, adminUgnotBalance(testOperator))
	uassert.Equal(t, targetAmount, adminUgnotBalance(testUser))
	uassert.Equal(t, user2Before, adminUgnotBalance(testUser2))
	uassert.Equal(t, adminBefore, adminUgnotBalance(adminRealm))
}

func TestRequestFaucetsReturnsZeroWithoutDeficits(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	UnsetOperator(cross(cur), testAdmin)
	SetOperator(cross(cur), testOperator)
	SetOperator(cross(cur), testUser)

	operatorBefore := adminUgnotBalance(testOperator)
	userBefore := adminUgnotBalance(testUser)
	targetAmount := maxInt64(operatorBefore, userBefore)
	if operatorBefore < targetAmount {
		faucetTest.Issue(testOperator, targetAmount-operatorBefore)
	}
	if userBefore < targetAmount {
		faucetTest.Issue(testUser, targetAmount-userBefore)
	}
	if targetAmount <= 0 {
		targetAmount = 1
		faucetTest.Issue(testOperator, targetAmount)
		faucetTest.Issue(testUser, targetAmount)
	}

	adminBefore := adminUgnotBalance(adminRealmAddr())
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetFaucetTargetAmount(cross(cur), targetAmount)
	transferred := RequestFaucets(cross(cur))

	uassert.Equal(t, int64(0), transferred)
	uassert.Equal(t, adminBefore, adminUgnotBalance(adminRealmAddr()))
}

func TestRequestFaucetRejectsInvalidRequest(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		setup    func(cur realm) (address, runtime.Realm)
		panicMsg string
	}{
		{
			name: "non-operator direct caller",
			setup: func(cur realm) (address, runtime.Realm) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetFaucetTargetAmount(cross(cur), 1000000)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return unauthorizedUser, testing.NewUserRealm(unauthorizedUser)
			},
			panicMsg: "operator access required",
		},
		{
			name: "operator balance already reaches target",
			setup: func(cur realm) (address, runtime.Realm) {
				operatorBalance := adminUgnotBalance(testOperator)
				if operatorBalance == 0 {
					faucetTest.Issue(testOperator, 1)
					operatorBalance = 1
				}
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), operatorBalance)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testOperator, testing.NewUserRealm(testOperator)
			},
			panicMsg: "operator balance is not below faucet target",
		},
		{
			name: "admin realm balance is insufficient",
			setup: func(cur realm) (address, runtime.Realm) {
				adminBalance := adminUgnotBalance(adminRealmAddr())
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), adminUgnotBalance(testOperator)+adminBalance+1)
				return testOperator, testing.NewUserRealm(testOperator)
			},
			panicMsg: "admin realm balance is insufficient",
		},
		{
			name: "operator origin through code realm",
			setup: func(cur realm) (address, runtime.Realm) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), adminUgnotBalance(testOperator)+1)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testOperator, testing.NewCodeRealm("gno.land/r/akkadia/beta/operator_faucet_relay")
			},
			panicMsg: "contract calls not allowed: function must be called directly by user",
		},
		{
			name: "target amount is not configured",
			setup: func(cur realm) (address, runtime.Realm) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testOperator, testing.NewUserRealm(testOperator)
			},
			panicMsg: "faucet target amount must be positive",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		caller, rlm := tt.setup(cur)
		testing.SetOriginCaller(caller)
		testing.SetRealm(rlm)

		uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
			RequestFaucet(cross(cur))
		})
	}
}

func TestRequestFaucetForRejectsInvalidRequest(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		setup    func(cur realm) (address, runtime.Realm, address)
		panicMsg string
	}{
		{
			name: "non-admin caller",
			setup: func(cur realm) (address, runtime.Realm, address) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), 1000000)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testOperator
			},
			panicMsg: "admin access required",
		},
		{
			name: "non-operator target",
			setup: func(cur realm) (address, runtime.Realm, address) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetFaucetTargetAmount(cross(cur), 1000000)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testAdmin, testing.NewUserRealm(testAdmin), unauthorizedUser
			},
			panicMsg: "operator access required",
		},
		{
			name: "operator balance already reaches target",
			setup: func(cur realm) (address, runtime.Realm, address) {
				operatorBalance := adminUgnotBalance(testOperator)
				if operatorBalance == 0 {
					faucetTest.Issue(testOperator, 1)
					operatorBalance = 1
				}
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), operatorBalance)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testAdmin, testing.NewUserRealm(testAdmin), testOperator
			},
			panicMsg: "operator balance is not below faucet target",
		},
		{
			name: "admin realm balance is insufficient",
			setup: func(cur realm) (address, runtime.Realm, address) {
				adminBalance := adminUgnotBalance(adminRealmAddr())
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), adminUgnotBalance(testOperator)+adminBalance+1)
				return testAdmin, testing.NewUserRealm(testAdmin), testOperator
			},
			panicMsg: "admin realm balance is insufficient",
		},
		{
			name: "target amount is not configured",
			setup: func(cur realm) (address, runtime.Realm, address) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testAdmin, testing.NewUserRealm(testAdmin), testOperator
			},
			panicMsg: "faucet target amount must be positive",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		caller, rlm, operator := tt.setup(cur)
		testing.SetOriginCaller(caller)
		testing.SetRealm(rlm)

		uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
			RequestFaucetFor(cross(cur), operator)
		})
	}
}

func TestRequestFaucetsRejectsInvalidRequest(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		setup    func(cur realm) (address, runtime.Realm)
		panicMsg string
	}{
		{
			name: "non-admin caller",
			setup: func(cur realm) (address, runtime.Realm) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), adminUgnotBalance(testOperator)+1)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return unauthorizedUser, testing.NewUserRealm(unauthorizedUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "admin realm balance is insufficient",
			setup: func(cur realm) (address, runtime.Realm) {
				adminBalance := adminUgnotBalance(adminRealmAddr())
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), adminUgnotBalance(testOperator)+adminBalance+1)
				return testAdmin, testing.NewUserRealm(testAdmin)
			},
			panicMsg: "admin realm balance is insufficient",
		},
		{
			name: "target amount is not configured",
			setup: func(cur realm) (address, runtime.Realm) {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				faucetTest.FundAdmin(testFaucetFundAmount)
				return testAdmin, testing.NewUserRealm(testAdmin)
			},
			panicMsg: "faucet target amount must be positive",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		caller, rlm := tt.setup(cur)
		testing.SetOriginCaller(caller)
		testing.SetRealm(rlm)

		uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
			RequestFaucets(cross(cur))
		})
	}
}

func TestWithdrawTransfersAdminRealmBalance(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	adminRealm := adminRealmAddr()
	adminBefore := adminUgnotBalance(adminRealm)
	recipientBefore := adminUgnotBalance(testUser)
	withdrawAmount := int64(200000)
	faucetTest.FundAdmin(withdrawAmount)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	transferred := Withdraw(cross(cur), testUser, withdrawAmount)

	uassert.Equal(t, withdrawAmount, transferred)
	uassert.Equal(t, recipientBefore+withdrawAmount, adminUgnotBalance(testUser))
	uassert.Equal(t, adminBefore, adminUgnotBalance(adminRealm))
}

type withdrawRejectContext struct {
	caller          address
	recipient       address
	amount          int64
	adminBefore     int64
	recipientBefore int64
	checkRecipient  bool
}

func TestWithdrawRejectsInvalidRequest(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		setup    func() withdrawRejectContext
		panicMsg string
	}{
		{
			name: "non-admin caller",
			setup: func() withdrawRejectContext {
				faucetTest.FundAdmin(1)
				return withdrawRejectContext{
					caller:    unauthorizedUser,
					recipient: testUser,
					amount:    1,
				}
			},
			panicMsg: "admin access required",
		},
		{
			name: "invalid recipient",
			setup: func() withdrawRejectContext {
				faucetTest.FundAdmin(1)
				return withdrawRejectContext{
					caller:    testAdmin,
					recipient: address(""),
					amount:    1,
				}
			},
			panicMsg: "invalid address",
		},
		{
			name: "zero amount",
			setup: func() withdrawRejectContext {
				faucetTest.FundAdmin(1)
				return withdrawRejectContext{
					caller:    testAdmin,
					recipient: testUser,
					amount:    0,
				}
			},
			panicMsg: "amount must be greater than 0",
		},
		{
			name: "negative amount",
			setup: func() withdrawRejectContext {
				faucetTest.FundAdmin(1)
				return withdrawRejectContext{
					caller:    testAdmin,
					recipient: testUser,
					amount:    -1,
				}
			},
			panicMsg: "amount must be greater than 0",
		},
		{
			name: "admin realm balance is insufficient",
			setup: func() withdrawRejectContext {
				return withdrawRejectContext{
					caller:    testAdmin,
					recipient: testUser,
					amount:    adminUgnotBalance(adminRealmAddr()) + 1,
				}
			},
			panicMsg: "admin realm balance is insufficient",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		ctx := tt.setup()
		ctx.adminBefore = adminUgnotBalance(adminRealmAddr())
		ctx.checkRecipient = ctx.recipient.IsValid()
		if ctx.checkRecipient {
			ctx.recipientBefore = adminUgnotBalance(ctx.recipient)
		}
		testing.SetOriginCaller(ctx.caller)
		testing.SetRealm(testing.NewUserRealm(ctx.caller))

		uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
			Withdraw(cross(cur), ctx.recipient, ctx.amount)
		})
		uassert.Equal(t, ctx.adminBefore, adminUgnotBalance(adminRealmAddr()))
		if ctx.checkRecipient {
			uassert.Equal(t, ctx.recipientBefore, adminUgnotBalance(ctx.recipient))
		}
	}
}

func adminUgnotBalance(addr address) int64 {
	bnk := banker.NewReadonlyBanker()
	return bnk.GetCoins(addr).AmountOf("ugnot")
}

func (h *faucetTestHelper) FundAdmin(amount int64) {
	h.Issue(adminRealmAddr(), amount)
}

func (h *faucetTestHelper) Issue(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	testing.IssueCoins(addr, chain.Coins{{"ugnot", amount}})
}

func maxInt64(a int64, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
