package gnocial

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestQueriesAndSuccessor(cur realm, t *testing.T) {
	resetArena()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	admin := testutils.TestAddress("admin")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "Alice", "xin chao", "")
	mustAbort(t, cur, "body has markup", func() {
		Post(cross(cur), "<b>x</b>", "")
	})
	id := Post(cross(cur), "bai cong khai", "")
	gid := Post(cross(cur), "bi mat 42", "yes")

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "Bob", "", alice.String())
	Reply(cross(cur), id, "tra loi 1")
	reply2 := Reply(cross(cur), id, "tra loi 2")

	rows := Feed(0, 8)
	urequire.Equal(t, true, len(rows) >= 2)
	urequire.Equal(t, false, strings.Contains(Render(""), "bi mat 42"))
	urequire.Equal(t, false, strings.Contains(Render(""), "bai cong khai"))
	secret, ok := GetPost(gid)
	urequire.Equal(t, true, ok)
	urequire.Equal(t, "bi mat 42", secret.Body)

	people := Handles("", 1)
	urequire.Equal(t, 1, len(people))
	urequire.Equal(t, "alice", people[0].Handle)
	next := Handles(people[0].Handle, 1)
	urequire.Equal(t, "bob", next[0].Handle)

	reps := Replies(id, 0, 1)
	urequire.Equal(t, 1, len(reps))
	urequire.Equal(t, "tra loi 1", reps[0].Body)
	rest := Replies(id, reps[0].ID, 1)
	urequire.Equal(t, reply2, rest[0].ID)

	due, _, _, _, _ := QuoteBuy("alice", 1)
	urequire.Equal(t, int64(11000), due)
	acc, ok := ProfileOf(alice)
	urequire.Equal(t, true, ok)
	urequire.Equal(t, "xin chao", acc.Bio)
	urequire.Equal(t, 2, MemberCount())
	urequire.Equal(t, true, LatestID() >= reply2)

	if !uassert.PanicsWithMessage(t, cur, "limit", func() { Feed(0, 0) }) {
		t.FailNow()
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "admin only", func() {
		SetSuccessor(cross(cur), "gno.land/r/demo/next")
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	testing.SetOriginSend(ugnots(1))
	mustAbort(t, cur, "this call takes no payment", func() {
		SetSuccessor(cross(cur), "gno.land/r/demo/next")
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "bad successor", func() {
		SetSuccessor(cross(cur), "gno.land/r/demo/next.v2")
	})
	reserve := TotalReserve()
	SetSuccessor(cross(cur), "gno.land/r/demo/next")
	urequire.Equal(t, "gno.land/r/demo/next", Successor())
	urequire.Equal(t, reserve, TotalReserve())
	urequire.Equal(t, true, strings.Contains(Render("about"), "gno.land/r/demo/next"))
	SetSuccessor(cross(cur), "")
	urequire.Equal(t, "", Successor())
}
