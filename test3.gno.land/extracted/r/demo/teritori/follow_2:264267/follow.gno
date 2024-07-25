package follow

import (
	"std"
	"strings"

	"gno.land/p/demo/avl"
)

type User struct {
	address std.Address
	followers avl.Tree
	followeds avl.Tree
}

var (
	addr2User  avl.Tree // std.Address -> *User
)

func getOrCreateUser(addr std.Address) *User {
	userI, ok := addr2User.Get(addr.String())
	if ok {
		return userI.(*User)
	}
	user := &User{
		address: addr,
	}
	addr2User.Set(addr.String(), user)
	return user
}

func Follow(addr std.Address) {
	// get caller/inviter.
	caller := std.GetOrigCaller()
	callerUser := getOrCreateUser(caller)
	user := getOrCreateUser(addr)
	callerUser.followeds.Set(addr.String(), user)
	user.followers.Set(caller.String(), callerUser)
}

func Unfollow(addr std.Address) {
	// get caller/inviter.
	caller := std.GetOrigCaller()
	callerUser := getOrCreateUser(caller)
	user := getOrCreateUser(addr)
	if  _, ok := callerUser.followeds.Remove(addr.String()); !ok {
		panic("followed not found")
	}
	if _, ok := user.followers.Remove(caller.String()); !ok {
		panic("follower not found")
	}
}

func Followers(addr std.Address) []std.Address {
	userI, ok := addr2User.Get(addr.String())
	if !ok {
		return nil
	}
	user := userI.(*User)
	followers := make([]std.Address, 0, user.followers.Size())
	user.followers.Iterate("", "",  func(key string, value interface{}) bool  {
		follower := value.(*User)
		followers = append(followers, follower.address)
		return false
	})
	return followers
}

func FollowedCount(addr std.Address) uint{
	userI, ok := addr2User.Get(addr.String())
	if !ok {
		return 0
	}
	user := userI.(*User)
	return uint(user.followeds.Size())
}

func Followed(addr std.Address) []std.Address {
	userI, ok := addr2User.Get(addr.String())
	if !ok {
		return nil
	}
	user := userI.(*User)
	followeds := make([]std.Address, 0, user.followeds.Size())
	user.followeds.Iterate("", "",  func(key string, value interface{}) bool  {
		followed := value.(*User)
		followeds = append(followeds, followed.address)
		return false
	})
	return followeds
}

func FollowersCount(addr std.Address) uint {
	userI, ok := addr2User.Get(addr.String())
	if !ok {
		return 0
	}
	user := userI.(*User)
	return uint(user.followers.Size())
}

func IsFollower(follower std.Address, followed std.Address) bool {
	userI, ok := addr2User.Get(followed.String())
	if !ok {
		return false
	}
	user := userI.(*User)
	_, ok = user.followers.Get(follower.String())
	return ok
}