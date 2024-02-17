package follow

import(
	"gno.land/p/demo/avl"
	"std"
)


var users avl.Tree



func Follow(addr std.Address) {
	
	if string(std.GetOrigCaller()) == string(addr) {
		panic("You cannot follow yourself")
	}
	callerUser := getUser(std.GetOrigCaller())
	followedUser := getUser(addr)

	if _,ok:=callerUser.Following().Get(string(addr)); ok{
		panic("You Already follow this user")
	}
	callerUser.Follow(followedUser)
}

func Unfollow(addr std.Address) {
	callerUser := getUser(std.GetOrigCaller())
	if _,ok:=callerUser.Following().Get(string(addr)); !ok{
		panic("You cannot unfollow a non followed user")
	}

	unfollowedUser := getUser(addr)

	callerUser.Unfollow(unfollowedUser)
}


func Followers(addr std.Address) []std.Address {
	followers := getUser(addr).Followers()
	res := make([]std.Address,0, followers.Size())
	followers.Iterate("","", func(key string, data interface{}) bool{		
		res = append(res, data.(std.Address))
		return false
	})
	return res
}

func Followed(addr std.Address) []std.Address {
	followers := getUser(addr).Following()
	res := make([]std.Address, 0, followers.Size())
	followers.Iterate("","", func(key string, data interface{}) bool{		
		res = append(res, data.(std.Address))
		return false
	})
	return res
}

func FollowersCount(addr std.Address) uint {
	return uint(getUser(addr).Followers().Size())
}

func FollowedCount(addr std.Address) uint {
	return uint(getUser(addr).Following().Size())
}

func IsFollower(follower std.Address, followed std.Address) bool {
	_, isFollower := getUser(follower).Following().Get(string(followed))
	return isFollower
}

func getUser(addr std.Address) *User {
	user,ok := users.Get(string(addr))
	if ok{
		return user.(*User)
	}
	newUser := NewUser(addr)
	users.Set(string(addr), newUser)
	return newUser
}