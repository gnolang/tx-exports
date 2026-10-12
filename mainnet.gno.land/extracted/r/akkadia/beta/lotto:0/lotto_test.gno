package lotto

import (
	"strconv"
	"testing"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

func TestAddNumber(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	for _, caller := range []address{testAdmin, testOperator} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		for i := 0; i < 3; i++ {
			AddNumber(cross(cur), testOwner, 123456)
		}
	}
	uassert.Equal(t, GetNumberCount(123456, testOwner), uint64(6))
	uassert.Equal(t, holdings.Size(), 1)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddNumber(cross(cur), testOther, 123456)
	AddNumber(cross(cur), testOwner, 654321)
	uassert.Equal(t, GetNumberCount(123456, testOwner), uint64(6))
	uassert.Equal(t, GetNumberCount(123456, testOther), uint64(1))
	uassert.Equal(t, GetNumberCount(654321, testOwner), uint64(1))
	uassert.Equal(t, GetNumberCount(654321, testOther), uint64(0))
	uassert.Equal(t, holdings.Size(), 3)
	page := ListOwnersByNumber(123456, "", 100)
	uassert.Equal(t, len(page), 2)
	uassert.Equal(t, page[0]["nextOwner"], "")
	for _, item := range page {
		uassert.Equal(t, item["count"], strconv.FormatUint(GetNumberCount(123456, address(item["owner"])), 10))
	}
}

func TestAddNumberAuthority(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddNumber(cross(cur), testOwner, 1)
	for _, caller := range []address{testOwner, testOther} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
			AddNumber(cross(cur), testOwner, 1)
		})
		uassert.Equal(t, GetNumberCount(1, testOwner), uint64(1))
	}
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.UnsetOperator(cross(cur), testOperator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		AddNumber(cross(cur), testOwner, 1)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.SetOperator(cross(cur), testOperator)
	for _, signer := range []address{testAdmin, testOperator} {
		testing.SetOriginCaller(signer)
		testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/lotto_relay"))
		uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
			AddNumber(cross(cur), testOwner, 1)
		})
	}
	// Probe the actual helper with a foreign realm, without cross(stale) masking
	// its spoofed-realm assertion with a builtin crossing failure.
	spoofed := cur.Previous()
	uassert.PanicsWithMessage(t, cur, "spoofed realm", func() {
		accesscontrol.MustGetAdminOrOperatorCaller(0, spoofed, admin.IsAdmin, admin.IsOperator)
	})
	uassert.Equal(t, GetNumberCount(1, testOwner), uint64(1))
	uassert.Equal(t, holdings.Size(), 1)
}

func TestAddNumberValidation(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	for _, number := range []uint64{0, ^uint64(0)} {
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		AddNumber(cross(cur), testOwner, number)
		uassert.Equal(t, GetNumberCount(number, testOwner), uint64(1))
		uassert.Equal(t, ListOwnersByNumber(number, "", 1)[0]["owner"], testOwner.String())
	}
	for _, owner := range []address{"", "invalid", address(testOwner.String() + "x")} {
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		uassert.AbortsWithMessage(t, cur, "invalid address", func() {
			AddNumber(cross(cur), owner, 1)
		})
		uassert.PanicsWithMessage(t, cur, "invalid address", func() { GetNumberCount(1, owner) })
		if owner != "" {
			uassert.PanicsWithMessage(t, cur, "invalid address", func() {
				ListOwnersByNumber(1, owner.String(), 1)
			})
		}
	}
	uassert.Equal(t, holdings.Size(), 2)
	// Overflow cannot be reached economically through repeated public calls.
	holdings.Set("1:"+testOwner.String(), ^uint64(0))
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	uassert.AbortsWithMessage(t, cur, "number count overflow", func() {
		AddNumber(cross(cur), testOwner, 1)
	})
	uassert.Equal(t, GetNumberCount(1, testOwner), ^uint64(0))
	uassert.Equal(t, ListOwnersByNumber(1, "", 1)[0]["count"], "18446744073709551615")
	uassert.Equal(t, holdings.Size(), 3)
}

func TestListOwnersByNumber(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	uassert.Equal(t, len(ListOwnersByNumber(1, "", 100)), 0)

	uassert.Equal(t, GetNumberCount(1, testOwner), uint64(0))
	uassert.Equal(t, holdings.Size(), 0)
	for _, limit := range []int{-1, 0, 101} {
		uassert.PanicsWithMessage(t, cur, "limit must be between 1 and 100", func() {
			ListOwnersByNumber(1, "", limit)
		})
	}
	for _, number := range []uint64{1, 10, 100} {
		for i := 0; i < 105; i++ {
			testing.SetRealm(testing.NewUserRealm(testAdmin))
			owner := testutils.TestAddress("lottoPage" + strconv.FormatUint(number, 10) + ":" + strconv.Itoa(i))
			AddNumber(cross(cur), owner, number)
			if i%2 == 0 {
				AddNumber(cross(cur), owner, number)
			}
		}
	}
	for _, number := range []uint64{1, 10, 100} {
		for _, limit := range []int{1, 7, 100} {
			after := ""
			seen := 0
			for {
				page := ListOwnersByNumber(number, after, limit)
				for _, item := range page {
					uassert.True(t, item["owner"] > after)
					uassert.Equal(t, item["nextOwner"], page[0]["nextOwner"])
					uassert.Equal(t, item["count"], strconv.FormatUint(GetNumberCount(number, address(item["owner"])), 10))
					after = item["owner"]
					seen++
				}
				if len(page) == 0 || page[0]["nextOwner"] == "" {
					break
				}
				uassert.Equal(t, len(page), limit)
				uassert.Equal(t, page[0]["nextOwner"], after)
			}
			uassert.Equal(t, seen, 105)
			uassert.Equal(t, len(ListOwnersByNumber(number, after, limit)), 0)
		}
	}
	uassert.Equal(t, holdings.Size(), 315)
	uassert.Equal(t, len(ListOwnersByNumber(1000, "", 100)), 0)
	// A valid cursor between stored owners does not have to be stored itself.
	missing := testutils.TestAddress("lottoMissing").String()
	uassert.Equal(t, GetNumberCount(1, address(missing)), uint64(0))
	first := ListOwnersByNumber(1, "", 100)
	all := append(first, ListOwnersByNumber(1, first[0]["nextOwner"], 100)...)
	expected := []map[string]string{}
	for _, item := range all {
		if item["owner"] > missing {
			expected = append(expected, item)
		}
	}
	page := ListOwnersByNumber(1, missing, 100)
	actual := page
	if len(page) > 0 && page[0]["nextOwner"] != "" {
		actual = append(actual, ListOwnersByNumber(1, page[0]["nextOwner"], 100)...)
	}
	uassert.Equal(t, len(actual), len(expected))
	for i, item := range actual {
		uassert.Equal(t, item["owner"], expected[i]["owner"])
		uassert.Equal(t, item["count"], expected[i]["count"])
	}
	fresh := ListOwnersByNumber(1, "", 1)
	original := map[string]string{"owner": fresh[0]["owner"], "count": fresh[0]["count"]}
	fresh[0]["owner"] = testOther.String()
	fresh[0]["count"] = "999"
	fresh[0]["nextOwner"] = "changed"
	uassert.Equal(t, ListOwnersByNumber(1, "", 1)[0]["owner"], original["owner"])
	uassert.Equal(t, ListOwnersByNumber(1, "", 1)[0]["count"], original["count"])
	uassert.Equal(t, strconv.FormatUint(GetNumberCount(1, address(original["owner"])), 10), original["count"])
	uassert.Equal(t, holdings.Size(), 315)
}

func TestDeleteAll(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddNumber(cross(cur), testOwner, 1)
	AddNumber(cross(cur), testOwner, 1)
	AddNumber(cross(cur), testOther, 1)
	AddNumber(cross(cur), testOwner, 2)

	DeleteAll(cross(cur))
	uassert.Equal(t, holdings.Size(), 0)
	for _, number := range []uint64{1, 2} {
		for _, owner := range []address{testOwner, testOther} {
			uassert.Equal(t, GetNumberCount(number, owner), uint64(0))
		}
		uassert.Equal(t, len(ListOwnersByNumber(number, "", 100)), 0)
	}
	DeleteAll(cross(cur))
	// Operators can register again, starting from one instead of the old count.
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	AddNumber(cross(cur), testOwner, 1)
	uassert.Equal(t, GetNumberCount(1, testOwner), uint64(1))
	uassert.Equal(t, holdings.Size(), 1)
	uassert.Equal(t, len(ListOwnersByNumber(1, "", 100)), 1)
}

func TestDeleteAllAuthority(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddNumber(cross(cur), testOwner, 1)
	for _, caller := range []address{testOwner, testOperator} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		uassert.AbortsWithMessage(t, cur, "admin access required", func() {
			DeleteAll(cross(cur))
		})
		uassert.Equal(t, GetNumberCount(1, testOwner), uint64(1))
		uassert.Equal(t, holdings.Size(), 1)
	}
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/lotto_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		DeleteAll(cross(cur))
	})
	uassert.Equal(t, GetNumberCount(1, testOwner), uint64(1))
	uassert.Equal(t, holdings.Size(), 1)
}
