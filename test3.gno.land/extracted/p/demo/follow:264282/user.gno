package follow

import(
	"gno.land/p/demo/avl"
	"std"
)

type User struct{
	following *avl.Tree
	followers *avl.Tree
	address std.Address
}

func NewUser(address std.Address) *User {
	return &User{
		following: &avl.Tree{},
		followers: &avl.Tree{},
		address: address,
	}
}


func( user*User) Following() *avl.Tree{
	return user.following
}

func( user*User) Followers() *avl.Tree{
	return user.followers
}


func( user*User) Follow(followedUser *User) {
	followedUser.addFollower(user.Address())
	user.follow(followedUser.Address())
}

func( user*User) Unfollow(followedUser *User) {
	user.following.Remove(string(followedUser.Address()))
	followedUser.followers.Remove(string(user.Address()))
}

func( user*User) addFollower(addr std.Address){
	user.followers.Set(string(addr), addr)
}

func( user*User) follow(addr std.Address){
	user.following.Set(string(addr), addr)
}

func( user*User) Address() std.Address {
	return  user.address
}