package follow

import(
	"gno.land/p/demo/avl"
	"gno.land/p/demo/testutils"
	"testing"
	"std"
)

var caller std.Address
var test2 std.Address
func init() {
	caller = testutils.TestAddress("testUser") // main
	test2 = testutils.TestAddress("test2")
	// register as caller
	std.TestSetOrigCaller(caller)
}

func TestFollow_Unfollow(t *testing.T) {
	users = avl.Tree{}

	count := FollowersCount(test2)
	if count != 0 {
        t.Fatalf("Initial followers != 0")
    }
	
	isFollower := IsFollower(caller, test2)
	if isFollower{
        t.Fatalf("is follower before follow")
    }
	Follow(test2)

	isFollower = IsFollower(caller, test2)
	if !isFollower{
        t.Fatalf("Should be follower")
    }
	count = FollowersCount(test2)
	if count != 1 {
        t.Fatalf("followers != 1")
    }

	count = FollowedCount(test2)
	if count != 0 {
        t.Fatalf("followers != 0")
    }

	count = FollowedCount(caller)
	if count != 1 {
        t.Fatalf("followers != 1")
    }

	followers:=Followers(test2)
	if string(followers[0]) != string(caller) {
		t.Fatalf("Different address")
	}

	followed:=Followed(caller)
	if string(followed[0]) != string(test2) {
		t.Fatalf("Different address")
	}

	Unfollow(test2)
	count = FollowersCount(test2)
	if count != 0 {
        t.Fatalf("followers != 0")
    }

	isFollower = IsFollower(caller, test2)
	if isFollower{
        t.Fatalf("is follower after unfollow")
    }
}

func TestFollow_twice(t *testing.T) {
	users = avl.Tree{}
	test2 := testutils.TestAddress("test2")
	defer func() {
        if r := recover(); r == nil {
			t.Fatalf("should've panic")
        }
    }()
	caller := std.GetOrigCaller() 
	Follow(test2)
	Follow(test2)
}