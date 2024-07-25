package follow


import (
	"std"
	"testing"

	"gno.land/p/demo/testutils"
)


func TestFollow_Follow(t *testing.T) {
	user := testutils.TestAddress("user")
	std.TestSetOrigCaller(user)
	

	Follow(user)
	
	if c := FollowersCount(user); c != 1 {
		t.Fatalf("FollowersCount expected to have 1 has %d", c)
	}

	if followers := Followers(user); followers[0].String() != string(user) {
		t.Fatalf("Followers expected to have %s has %s", string(user), followers[0].String())
	}

	if followed := Followed(user); followed[0].String() != string(user) {
		t.Fatalf("Followed expected to have %s has %s", followed[0].String())
	}
}

func TestFollow_UnFollow(t *testing.T) {
	caller := std.GetOrigCaller()
	Follow(caller)
	Unfollow(caller)
	if c := FollowersCount(caller); c != 0 {
		t.Fatalf("expected to have 0 has %d", c)
	}
}


