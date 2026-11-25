package grc1155

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

type evilTeller struct{ Teller }

func TestIsCanonicalTeller(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)

	var realmTeller Teller
	func(cur realm) {
		realmTeller = tok.RealmTeller(0, cur)
	}(cross(cur))

	tests := []struct {
		name string
		te   Teller
		want bool
	}{
		{"CallerTeller is canonical", led.CallerTeller(), true},
		{"ReadonlyTeller is canonical", tok.ReadonlyTeller(), true},
		{"RealmTeller is canonical", realmTeller, true},
		{"ImpersonateTeller is canonical", led.ImpersonateTeller(alice), true},
		{"embedding wrapper is rejected", &evilTeller{led.CallerTeller()}, false},
		{"embedding wrapper of readonly is rejected", &evilTeller{tok.ReadonlyTeller()}, false},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			uassert.Equal(t, tc.want, IsCanonicalTeller(tc.te))
		})
	}
}

func TestTellerNilGuards(cur realm, t *testing.T) {
	var nilTok *Token
	var nilLed *PrivateLedger

	tests := []struct {
		name string
		msg  string
		fn   func()
	}{
		{"CallerTeller on nil ledger panics", "Ledger cannot be nil", func() {
			nilLed.CallerTeller()
		}},
		{"ReadonlyTeller on nil token panics", "Token cannot be nil", func() {
			nilTok.ReadonlyTeller()
		}},
		{"RealmTeller on nil token panics", "Token cannot be nil", func() {
			nilTok.RealmTeller(0, cur)
		}},
		{"RealmSubTeller on nil token panics", "Token cannot be nil", func() {
			nilTok.RealmSubTeller(0, cur, "slug")
		}},
		{"ImpersonateTeller on nil ledger panics", "Ledger cannot be nil", func() {
			nilLed.ImpersonateTeller(alice)
		}},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			uassert.PanicsWithMessage(t, cur, tc.msg, tc.fn)
		})
	}
}

func TestReadonlyTeller(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	ro := tok.ReadonlyTeller()

	// Reads still work through the teller.
	uassert.Equal(t, "Foo", ro.GetName())
	uassert.Equal(t, "FOO", ro.GetSymbol())
	uassert.Equal(t, tok.ID(), ro.ID())
	uassert.Equal(t, int64(5), ro.TotalSupply("wood"))
	bal, err := ro.BalanceOf(alice, "wood")
	urequire.NoError(t, err)
	uassert.Equal(t, int64(5), bal)

	tests := []struct {
		name string
		op   string
	}{
		{"SetApprovalForAll rejected with ErrReadonly", "setall"},
		{"TransferFrom rejected with ErrReadonly", "transfer"},
		{"BatchTransferFrom rejected with ErrReadonly", "batch"},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			var err error
			testing.SetRealm(testing.NewUserRealm(alice))
			func(cur realm) {
				switch tc.op {
				case "setall":
					err = ro.SetApprovalForAll(0, cur, bob, true)
				case "transfer":
					err = ro.TransferFrom(0, cur, alice, bob, "wood", 1)
				case "batch":
					err = ro.BatchTransferFrom(0, cur, alice, bob, []TokenID{"wood"}, []int64{1})
				}
			}(cross(cur))
			uassert.ErrorIs(t, err, ErrReadonly)
		})
	}
}

func TestCallerTellerFlow(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	urequire.NoError(t, led.Mint(alice, "ore", 3))

	teller := led.CallerTeller()

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) {
		urequire.NoError(t, teller.SetApprovalForAll(0, cur, bob, true))
	}(cross(cur))
	uassert.True(t, tok.IsApprovedForAll(alice, bob))

	testing.SetRealm(testing.NewUserRealm(bob))
	func(cur realm) {
		urequire.NoError(t, teller.TransferFrom(0, cur, alice, carl, "wood", 2))
		urequire.NoError(t, teller.BatchTransferFrom(0, cur, alice, carl,
			[]TokenID{"ore", "wood"}, []int64{1, 1}))
	}(cross(cur))

	uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "wood"))
	uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
	uassert.Equal(t, int64(3), mustBalanceOf(t, tok, carl, "wood"))
	uassert.Equal(t, int64(1), mustBalanceOf(t, tok, carl, "ore"))

	testing.SetRealm(testing.NewUserRealm(bob))
	func(cur realm) {
		uassert.ErrorIs(t, teller.TransferFrom(0, cur, carl, bob, "wood", 1), ErrCallerIsNotOwnerOrApproved)
	}(cross(cur))
}

func TestCallerTellerSpoofedRealm(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	teller := led.CallerTeller()

	// Stale outer cur while a fresh frame is current → ErrSpoofedRealm.
	tests := []struct {
		name string
		op   string
	}{
		{"SetApprovalForAll rejects spoofed realm", "setall"},
		{"TransferFrom rejects spoofed realm", "transfer"},
		{"BatchTransferFrom rejects spoofed realm", "batch"},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			var err error
			stale := cur
			func(cur realm) {
				switch tc.op {
				case "setall":
					err = teller.SetApprovalForAll(0, stale, bob, true)
				case "transfer":
					err = teller.TransferFrom(0, stale, alice, bob, "wood", 1)
				case "batch":
					err = teller.BatchTransferFrom(0, stale, alice, bob, []TokenID{"wood"}, []int64{1})
				}
			}(cross(cur))
			uassert.ErrorIs(t, err, ErrSpoofedRealm)
		})
	}
}

func TestRealmTellerFlow(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)

	var teller Teller
	var realmAddr address
	func(cur realm) {
		teller = tok.RealmTeller(0, cur)
		realmAddr = cur.Address()
	}(cross(cur))

	urequire.NoError(t, led.Mint(realmAddr, "wood", 4))

	testing.SetRealm(testing.NewUserRealm(alice))
	func(cur realm) {
		urequire.NoError(t, teller.TransferFrom(0, cur, realmAddr, bob, "wood", 1))
	}(cross(cur))

	uassert.Equal(t, int64(3), mustBalanceOf(t, tok, realmAddr, "wood"))
	uassert.Equal(t, int64(1), mustBalanceOf(t, tok, bob, "wood"))
}

func TestRealmSubTellerFlow(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)

	tests := []struct {
		name           string
		slug           string
		tid            TokenID
		wantsRealmAddr bool
	}{
		{"empty slug derives the realm address itself", "", "wood", true},
		{"non-empty slug derives a sub-account", "vault", "ore", false},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			var teller Teller
			var realmAddr, account address
			func(cur realm) {
				teller = tok.RealmSubTeller(0, cur, tc.slug)
				realmAddr = cur.Address()
				account = accountSlugAddr(cur.Address(), tc.slug)
			}(cross(cur))

			if tc.wantsRealmAddr {
				uassert.Equal(t, realmAddr, account)
			} else {
				uassert.True(t, realmAddr != account, "sub-account must differ from realm address")
			}

			urequire.NoError(t, led.Mint(account, tc.tid, 3))
			testing.SetRealm(testing.NewUserRealm(alice))
			func(cur realm) {
				urequire.NoError(t, teller.TransferFrom(0, cur, account, bob, tc.tid, 1))
			}(cross(cur))

			uassert.Equal(t, int64(2), mustBalanceOf(t, tok, account, tc.tid))
			uassert.Equal(t, int64(1), mustBalanceOf(t, tok, bob, tc.tid))
		})
	}
}

func TestRealmTellerSpoofedRealm(cur realm, t *testing.T) {
	tok, _ := newTestToken("Foo", "FOO", "", cur)

	tests := []struct {
		name string
		fn   func()
	}{
		{"RealmTeller rejects spoofed realm", func() {
			stale := cur
			func(cur realm) {
				tok.RealmTeller(0, stale)
			}(cross(cur))
		}},
		{"RealmSubTeller rejects spoofed realm", func() {
			stale := cur
			func(cur realm) {
				tok.RealmSubTeller(0, stale, "vault")
			}(cross(cur))
		}},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			urequire.AbortsContains(t, cur, "rlm does not match the current crossing frame", tc.fn)
		})
	}
}

func TestImpersonateTeller(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))

	teller := led.ImpersonateTeller(alice)
	testing.SetRealm(testing.NewUserRealm(bob))
	func(cur realm) {
		urequire.NoError(t, teller.TransferFrom(0, cur, alice, bob, "wood", 2))
		urequire.NoError(t, teller.BatchTransferFrom(0, cur, alice, bob,
			[]TokenID{"wood"}, []int64{1}))
	}(cross(cur))

	uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "wood"))
	uassert.Equal(t, int64(3), mustBalanceOf(t, tok, bob, "wood"))
}

func TestImpersonateTellerRejectsInvalidAddress(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "", cur)
	uassert.PanicsWithMessage(t, cur, "invalid address", func() {
		led.ImpersonateTeller(zeroAddress)
	})
	// Bech32 uppercase is IsValid() but not a canonical ledger key.
	uassert.PanicsWithMessage(t, cur, "invalid address", func() {
		led.ImpersonateTeller(address(strings.ToUpper(alice.String())))
	})
}
