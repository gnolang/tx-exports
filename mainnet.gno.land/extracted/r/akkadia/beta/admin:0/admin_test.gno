package admin

import (
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/uassert/v0"
)

// ==================== Admin Tests ====================

func TestTransferAdmin(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		newAdmin     address
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin transfers", testAdmin, testing.NewUserRealm(testAdmin), testUser, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testUser, true, "admin access required"},
		{"invalid address", testAdmin, testing.NewUserRealm(testAdmin), address(""), true, "invalid address"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				TransferAdmin(cross(cur), tt.newAdmin)
			})
		} else {
			TransferAdmin(cross(cur), tt.newAdmin)
			uassert.Equal(t, testAdmin.String(), GetAdmin().String())
			uassert.Equal(t, tt.newAdmin.String(), GetPendingAdmin().String())
			uassert.True(t, IsAdmin(testAdmin))
			uassert.False(t, IsAdmin(tt.newAdmin))
		}
	}
}

func TestAcceptAdmin(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		setup        func()
		originCaller address
		realm        runtime.Realm
		shouldPanic  bool
		panicMsg     string
	}{
		{
			name: "pending admin accepts",
			setup: func() {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
			},
			originCaller: testUser,
			realm:        testing.NewUserRealm(testUser),
		},
		{
			name: "unauthorized user cannot accept",
			setup: func() {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
			},
			originCaller: unauthorizedUser,
			realm:        testing.NewUserRealm(unauthorizedUser),
			shouldPanic:  true,
			panicMsg:     "pending admin access required",
		},
		{
			name:         "missing pending admin",
			originCaller: testAdmin,
			realm:        testing.NewUserRealm(testAdmin),
			shouldPanic:  true,
			panicMsg:     "invalid pending admin address",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))

		if tt.setup != nil {
			tt.setup()
		}

		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				AcceptAdmin(cross(cur))
			})
			continue
		}

		AcceptAdmin(cross(cur))
		uassert.Equal(t, tt.originCaller.String(), GetAdmin().String())
		uassert.Equal(t, "", GetPendingAdmin().String())
	}
}

func TestTransferAdmin_RejectsPendingOverwrite(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	TransferAdmin(cross(cur), testUser)
	uassert.Equal(t, testUser.String(), GetPendingAdmin().String())

	uassert.AbortsWithMessage(t, cur, "pending admin transfer already exists", func() {
		TransferAdmin(cross(cur), testUser2)
	})
	uassert.Equal(t, testAdmin.String(), GetAdmin().String())
	uassert.Equal(t, testUser.String(), GetPendingAdmin().String())
}

func TestTransferAdmin_AllowsOriginOnlyForEmptyBootstrapAdmin(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)
	admin = address("")

	testing.SetOriginCaller(address(""))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_bootstrap_relay"))
	TransferAdmin(cross(cur), testUser)
	uassert.Equal(t, "", GetAdmin().String())
	uassert.Equal(t, testUser.String(), GetPendingAdmin().String())

	testing.SetOriginCaller(testUser)
	testing.SetRealm(testing.NewUserRealm(testUser))
	AcceptAdmin(cross(cur))
	uassert.Equal(t, testUser.String(), GetAdmin().String())
	uassert.Equal(t, "", GetPendingAdmin().String())

	testing.SetOriginCaller(testUser)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay_after_bootstrap"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		TransferAdmin(cross(cur), testUser2)
	})
}

func TestAdminInterrealmSecurity(cur realm, t *testing.T) {
	tests := []struct {
		name        string
		setup       func(realm) realm
		call        func(realm, realm)
		shouldPanic bool
		panicMsg    string
		verify      func(t *testing.T)
	}{
		{
			name: "accept admin rejects code realm caller",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
				testing.SetOriginCaller(testUser)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/admin/relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				AcceptAdmin(cross(cur))
			},
			panicMsg: "contract calls not allowed: function must be called directly by user",
		},
		{
			name: "transfer admin rejects valid admin origin through code realm",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				TransferAdmin(cross(cur), testUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "transfer admin rejects non-admin origin through code realm",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(unauthorizedUser)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				TransferAdmin(cross(cur), testUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "cancel admin transfer",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				CancelAdminTransfer(cross(cur))
			},
			panicMsg: "admin access required",
		},
		{
			name: "set explorer url",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				SetExplorerURL(cross(cur), "https://relay.akkadia.land")
			},
			panicMsg: "admin access required",
		},
		{
			name: "set operator",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				SetOperator(cross(cur), testUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "unset operator",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testUser)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				UnsetOperator(cross(cur), testUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "set fee collector",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				SetFeeCollector(cross(cur), testUser)
			},
			panicMsg: "admin access required",
		},
		{
			name: "set protocol",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				SetProtocol(cross(cur), testProtocol)
			},
			panicMsg: "admin access required",
		},
		{
			name: "set faucet target amount",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				SetFaucetTargetAmount(cross(cur), 1000000)
			},
			panicMsg: "admin access required",
		},
		{
			name: "request faucet rejects operator origin through code realm",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				SetOperator(cross(cur), testOperator)
				SetFaucetTargetAmount(cross(cur), 1000000)
				testing.SetOriginCaller(testOperator)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_operator_faucet_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				RequestFaucet(cross(cur))
			},
			panicMsg: "contract calls not allowed: function must be called directly by user",
		},
		{
			name: "request faucet for",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				RequestFaucetFor(cross(cur), testOperator)
			},
			panicMsg: "admin access required",
		},
		{
			name: "request faucets",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				RequestFaucets(cross(cur))
			},
			panicMsg: "admin access required",
		},
		{
			name: "withdraw",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_relay"))
				return nil
			},
			call: func(cur realm, stale realm) {
				Withdraw(cross(cur), testUser, 1)
			},
			panicMsg: "admin access required",
		},
		{
			name: "assert current realm rejects stale realm",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_stale_probe"))
				return cur.Previous()
			},
			call: func(cur realm, stale realm) {
				accesscontrol.AssertCurrentRealm(0, stale)
			},
			shouldPanic: true,
			panicMsg:    "spoofed realm",
		},
		{
			name: "assert admin rejects stale realm",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_stale_probe"))
				return cur.Previous()
			},
			call: func(cur realm, stale realm) {
				accesscontrol.AssertIsAdmin(0, stale, IsAdmin)
			},
			shouldPanic: true,
			panicMsg:    "spoofed realm",
		},
		{
			name: "pending admin caller rejects stale realm",
			setup: func(cur realm) realm {
				pendingAdmin = testUser
				testing.SetOriginCaller(testAdmin)
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/admin_stale_probe"))
				return cur.Previous()
			},
			call: func(cur realm, stale realm) {
				mustGetPendingAdminUserCaller(0, stale)
			},
			shouldPanic: true,
			panicMsg:    "spoofed realm",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		stale := tt.setup(cur)
		call := func() {
			tt.call(cur, stale)
		}
		if tt.shouldPanic {
			uassert.PanicsWithMessage(t, cur, tt.panicMsg, call)
			continue
		}
		if tt.panicMsg != "" {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, call)
			continue
		}
		call()
		if tt.verify != nil {
			tt.verify(t)
		}
	}
}

func TestCancelAdminTransfer(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		setup        func()
		originCaller address
		realm        runtime.Realm
		shouldPanic  bool
		panicMsg     string
	}{
		{
			name: "admin cancels pending transfer",
			setup: func() {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
			},
			originCaller: testAdmin,
			realm:        testing.NewUserRealm(testAdmin),
		},
		{
			name: "unauthorized user cannot cancel",
			setup: func() {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				TransferAdmin(cross(cur), testUser)
			},
			originCaller: unauthorizedUser,
			realm:        testing.NewUserRealm(unauthorizedUser),
			shouldPanic:  true,
			panicMsg:     "admin access required",
		},
		{
			name:         "missing pending admin",
			originCaller: testAdmin,
			realm:        testing.NewUserRealm(testAdmin),
			shouldPanic:  true,
			panicMsg:     "invalid pending admin address",
		},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))

		if tt.setup != nil {
			tt.setup()
		}

		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				CancelAdminTransfer(cross(cur))
			})
			continue
		}

		CancelAdminTransfer(cross(cur))
		uassert.Equal(t, testAdmin.String(), GetAdmin().String())
		uassert.Equal(t, "", GetPendingAdmin().String())
	}
}

func TestCancelAdminTransfer_PreservesAdmin(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	TransferAdmin(cross(cur), testUser)

	CancelAdminTransfer(cross(cur))
	uassert.Equal(t, testAdmin.String(), GetAdmin().String())
	uassert.True(t, IsAdmin(testAdmin))
	uassert.Equal(t, "", GetPendingAdmin().String())
}

// ==================== ExplorerURL Tests ====================

func TestSetExplorerURL(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		url          string
		shouldPanic  bool
		panicMsg     string
		expectedURL  string
	}{
		{"admin sets url", testAdmin, testing.NewUserRealm(testAdmin), "https://new.explorer.com", false, "", "https://new.explorer.com"},
		{"trailing slash normalized", testAdmin, testing.NewUserRealm(testAdmin), "https://new.explorer.com///", false, "", "https://new.explorer.com"},
		{"admin sets empty url", testAdmin, testing.NewUserRealm(testAdmin), "", true, "explorer URL is required", ""},
		{"rejects http", testAdmin, testing.NewUserRealm(testAdmin), "http://new.explorer.com", true, "explorer URL must use https", ""},
		{"rejects whitespace", testAdmin, testing.NewUserRealm(testAdmin), " https://new.explorer.com", true, "invalid explorer URL", ""},
		{"rejects brackets", testAdmin, testing.NewUserRealm(testAdmin), "https://new.explorer.com/[test]", true, "invalid explorer URL", ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), "https://hacker.com", true, "admin access required", ""},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				SetExplorerURL(cross(cur), tt.url)
			})
			uassert.Equal(t, "https://app.beta.akkadia.land", GetExplorerURL())
		} else {
			SetExplorerURL(cross(cur), tt.url)
			uassert.Equal(t, tt.expectedURL, GetExplorerURL())
		}
	}
}

// ==================== Operator Tests ====================

func TestSetOperator(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		newAddr      address
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin sets operator", testAdmin, testing.NewUserRealm(testAdmin), testUser, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testUser, true, "admin access required"},
		{"invalid address", testAdmin, testing.NewUserRealm(testAdmin), address(""), true, "invalid address"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				SetOperator(cross(cur), tt.newAddr)
			})
		} else {
			SetOperator(cross(cur), tt.newAddr)
			uassert.True(t, IsOperator(tt.newAddr))
			uassert.True(t, IsOperator(testAdmin))
		}
	}
}

func TestGetOperators(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	operators := GetOperators()
	uassert.Equal(t, len(operators), 1)
	uassert.Equal(t, operators[0].String(), testAdmin.String())

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetOperator(cross(cur), testUser)

	operators = GetOperators()
	uassert.Equal(t, len(operators), 2)

	operators[0] = unauthorizedUser
	operatorsAgain := GetOperators()
	uassert.Equal(t, len(operatorsAgain), 2)
	uassert.False(t, containsOperator(operatorsAgain, unauthorizedUser))
}

func TestUnsetOperator(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		addr         address
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin unsets operator", testAdmin, testing.NewUserRealm(testAdmin), testUser, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testUser, true, "admin access required"},
		{"invalid address", testAdmin, testing.NewUserRealm(testAdmin), address(""), true, "invalid address"},
		{"not an operator", testAdmin, testing.NewUserRealm(testAdmin), unauthorizedUser, true, "address is not an operator"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		// Add testUser as operator for unset tests
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		SetOperator(cross(cur), testUser)

		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				UnsetOperator(cross(cur), tt.addr)
			})
		} else {
			UnsetOperator(cross(cur), tt.addr)
			uassert.False(t, IsOperator(tt.addr))
			uassert.True(t, IsOperator(testAdmin))
		}
	}
}

// ==================== FeeCollector Tests ====================

func TestSetFeeCollector(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		newAddr      address
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin sets feeCollector", testAdmin, testing.NewUserRealm(testAdmin), testUser, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testUser, true, "admin access required"},
		{"invalid address", testAdmin, testing.NewUserRealm(testAdmin), address(""), true, "invalid address"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				SetFeeCollector(cross(cur), tt.newAddr)
			})
			uassert.Equal(t, adminRealmAddr().String(), GetFeeCollector().String())
		} else {
			SetFeeCollector(cross(cur), tt.newAddr)
			uassert.Equal(t, tt.newAddr.String(), GetFeeCollector().String())
			uassert.True(t, IsFeeCollector(tt.newAddr))
			uassert.False(t, IsFeeCollector(testAdmin))
		}
	}
}

// ==================== Protocol Tests ====================

func TestSetProtocol(cur realm, t *testing.T) {
	tests := []struct {
		name         string
		originCaller address
		realm        runtime.Realm
		newAddr      address
		shouldPanic  bool
		panicMsg     string
	}{
		{"admin sets protocol", testAdmin, testing.NewUserRealm(testAdmin), testUser, false, ""},
		{"unauthorized", unauthorizedUser, testing.NewUserRealm(unauthorizedUser), testUser, true, "admin access required"},
		{"invalid address", testAdmin, testing.NewUserRealm(testAdmin), address(""), true, "invalid address"},
	}

	for _, tt := range tests {
		setupCommonAdminTests(cur, t)
		testing.SetOriginCaller(tt.originCaller)
		testing.SetRealm(tt.realm)

		if tt.shouldPanic {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, func() {
				SetProtocol(cross(cur), tt.newAddr)
			})
			uassert.Equal(t, testAdmin.String(), GetProtocol().String())
		} else {
			SetProtocol(cross(cur), tt.newAddr)
			uassert.Equal(t, tt.newAddr.String(), GetProtocol().String())
			uassert.True(t, IsProtocol(tt.newAddr))
			uassert.False(t, IsProtocol(testAdmin))
		}
	}
}

func TestRender(cur realm, t *testing.T) {
	setupCommonAdminTests(cur, t)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	SetOperator(cross(cur), testUser)
	SetFeeCollector(cross(cur), testUser2)
	SetProtocol(cross(cur), unauthorizedUser)
	SetFaucetTargetAmount(cross(cur), 1000000)

	output := Render("")
	uassert.True(t, strings.Contains(output, testAdmin.String()), "render should include admin")
	uassert.True(t, strings.Contains(output, testUser.String()), "render should include operator")
	uassert.True(t, strings.Contains(output, testUser2.String()), "render should include fee collector")
	uassert.True(t, strings.Contains(output, unauthorizedUser.String()), "render should include protocol")
	uassert.True(t, strings.Contains(output, "1000000 ugnot"), "render should include faucet target")
}
