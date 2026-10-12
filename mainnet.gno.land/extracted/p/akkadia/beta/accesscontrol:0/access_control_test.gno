package accesscontrol

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	testAdmin    = testutils.TestAddress("acAdmin")
	testOperator = testutils.TestAddress("acOperator")
	testUser     = testutils.TestAddress("acUser")
	testOther    = testutils.TestAddress("acOther")
)

func testIsAdmin(addr address) bool {
	return addr == testAdmin
}

func testIsOperator(addr address) bool {
	return addr == testOperator
}

func probeMustGetAdminCaller(cur realm, isAdmin AuthCheck) address {
	return MustGetAdminCaller(0, cur, isAdmin)
}

func probeAssertIsAdmin(cur realm, isAdmin AuthCheck) address {
	AssertIsAdmin(0, cur, isAdmin)
	return ""
}

func probeMustGetUserCaller(cur realm) address {
	return MustGetUserCaller(0, cur)
}

func probeMustGetAdminOrOperatorCaller(cur realm, isAdmin AuthCheck, isOperator AuthCheck) address {
	return MustGetAdminOrOperatorCaller(0, cur, isAdmin, isOperator)
}

func probeAssertIsAdminOrOperator(cur realm, isAdmin AuthCheck, isOperator AuthCheck) address {
	AssertIsAdminOrOperator(0, cur, isAdmin, isOperator)
	return ""
}

func TestAccessControl(cur realm, t *testing.T) {
	tests := []struct {
		label      string
		setup      func(realm) realm
		call       func(realm, realm) address
		panicKind  string
		panicMsg   string
		wantCaller address
	}{
		{
			label: "current realm",
			setup: func(cur realm) realm {
				return cur
			},
			call: func(cur realm, rlm realm) address {
				AssertCurrentRealm(0, rlm)
				return ""
			},
		},
		{
			label: "stale realm",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/accesscontrol_stale_probe"))
				return cur.Previous()
			},
			call: func(cur realm, rlm realm) address {
				AssertCurrentRealm(0, rlm)
				return ""
			},
			panicKind: "panic",
			panicMsg:  "spoofed realm",
		},
		{
			label: "admin caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetAdminCaller(cross(cur), testIsAdmin)
			},
			wantCaller: testAdmin,
		},
		{
			label: "assert admin caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeAssertIsAdmin(cross(cur), testIsAdmin)
			},
		},
		{
			label: "unauthorized admin caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testOther))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetAdminCaller(cross(cur), testIsAdmin)
			},
			panicKind: "abort",
			panicMsg:  "admin access required",
		},
		{
			label: "direct user caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testUser))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetUserCaller(cross(cur))
			},
			wantCaller: testUser,
		},
		{
			label: "code realm rejected as user caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewCodeRealm("gno.land/r/akkadia/beta/accesscontrol_relay"))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetUserCaller(cross(cur))
			},
			panicKind: "abort",
			panicMsg:  "contract calls not allowed: function must be called directly by user",
		},
		{
			label: "admin caller for admin or operator",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testAdmin))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetAdminOrOperatorCaller(cross(cur), testIsAdmin, testIsOperator)
			},
			wantCaller: testAdmin,
		},
		{
			label: "operator caller for admin or operator",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testOperator))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetAdminOrOperatorCaller(cross(cur), testIsAdmin, testIsOperator)
			},
			wantCaller: testOperator,
		},
		{
			label: "assert admin or operator",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testOperator))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeAssertIsAdminOrOperator(cross(cur), testIsAdmin, testIsOperator)
			},
		},
		{
			label: "unauthorized admin or operator caller",
			setup: func(cur realm) realm {
				testing.SetRealm(testing.NewUserRealm(testOther))
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return probeMustGetAdminOrOperatorCaller(cross(cur), testIsAdmin, testIsOperator)
			},
			panicKind: "abort",
			panicMsg:  "admin or operator access required",
		},
		{
			label: "admin origin",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return MustGetAdminOrigin(testIsAdmin)
			},
			wantCaller: testAdmin,
		},
		{
			label: "assert admin origin",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testAdmin)
				return nil
			},
			call: func(cur realm, rlm realm) address {
				AssertIsAdminOrigin(testIsAdmin)
				return ""
			},
		},
		{
			label: "unauthorized admin origin",
			setup: func(cur realm) realm {
				testing.SetOriginCaller(testOther)
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return MustGetAdminOrigin(testIsAdmin)
			},
			panicKind: "panic",
			panicMsg:  "admin access required",
		},
		{
			label: "nil admin check",
			setup: func(cur realm) realm {
				return cur
			},
			call: func(cur realm, rlm realm) address {
				return MustGetAdminCaller(0, rlm, nil)
			},
			panicKind: "panic",
			panicMsg:  "admin auth check is nil",
		},
		{
			label: "nil origin admin check",
			setup: func(cur realm) realm {
				return nil
			},
			call: func(cur realm, rlm realm) address {
				return MustGetAdminOrigin(nil)
			},
			panicKind: "panic",
			panicMsg:  "admin auth check is nil",
		},
		{
			label: "nil operator check",
			setup: func(cur realm) realm {
				return cur
			},
			call: func(cur realm, rlm realm) address {
				return MustGetAdminOrOperatorCaller(0, rlm, testIsAdmin, nil)
			},
			panicKind: "panic",
			panicMsg:  "operator auth check is nil",
		},
	}

	for _, tt := range tests {
		rlm := tt.setup(cur)
		call := func() {
			got := tt.call(cur, rlm)
			if tt.wantCaller != "" {
				uassert.Equal(t, tt.wantCaller.String(), got.String())
			}
		}

		if tt.panicKind == "panic" {
			uassert.PanicsWithMessage(t, cur, tt.panicMsg, call)
			continue
		}
		if tt.panicKind == "abort" {
			uassert.AbortsWithMessage(t, cur, tt.panicMsg, call)
			continue
		}
		call()
	}
}
