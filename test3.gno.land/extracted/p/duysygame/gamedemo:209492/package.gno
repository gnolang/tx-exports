package gamedemo

import (
	"regexp"
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/avl"
)

//----------------------------------------
// Types

type User struct {
	address std.Address
	name    string
	profile string
	number  int
	invites int
	inviter std.Address
}

func (u *User) Render() string {
	str := "## user " + u.name + "\n" +
		"\n" +
		" * address = " + string(u.address) + "\n" +
		" * " + strconv.Itoa(u.invites) + " invites\n"
	if u.inviter != "" {
		str = str + " * invited by " + string(u.inviter) + "\n"
	}
	str = str + "\n" +
		u.profile + "\n"
	return str
}

func (u User) Name() string         { return u.name }
func (u User) Profile() string      { return u.profile }
func (u User) Address() std.Address { return u.address }

//----------------------------------------
// State

var (
	admin      std.Address = "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
	name2User  avl.Tree                    // Name -> *User
	addr2User  avl.Tree                    // std.Address -> *User
	invites    avl.Tree                    // string(inviter+":"+invited) -> true
	counter    int                         // user id counter
	minFee     int64       = 200 * 1000000 // minimum gnot must be paid to register.
	maxFeeMult int64       = 10            // maximum multiples of minFee accepted.
)

//----------------------------------------
// Top-level functions

func Register(inviter std.Address, name string, profile string) {
	// assert CallTx call.
	std.AssertOriginCall()
	// assert invited or paid.
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	sentCoins := std.GetOrigSend()
	minCoin := std.Coin{"ugnot", minFee}
	if inviter == "" {
		// banker := std.GetBanker(std.BankerTypeOrigSend)
		if len(sentCoins) == 1 && sentCoins[0].IsGTE(minCoin) {
			if sentCoins[0].Amount > minFee*maxFeeMult {
				panic("payment must not be greater than " + strconv.Itoa(int(minFee*maxFeeMult)))
			} else {
				// ok
			}
		} else {
			panic("payment must not be less than " + strconv.Itoa(int(minFee)))
		}
	} else {
		invitekey := inviter.String() + ":" + caller.String()
		_, ok := invites.Get(invitekey)
		if !ok {
			panic("invalid invitation")
		}
		invites.Remove(invitekey)
	}
	// assert not already registered.
	_, ok := name2User.Get(name)
	if ok {
		panic("name already registered")
	}
	_, ok = addr2User.Get(caller.String())
	if ok {
		panic("address already registered")
	}
	// assert name is valid.
	if !reName.MatchString(name) {
		panic("invalid name: " + name + " (must be at least 6 characters, lowercase alphanumeric with underscore)")
	}
	// remainder of fees go toward invites.
	invites := int(0)
	if len(sentCoins) == 1 {
		if sentCoins[0].Denom == "ugnot" && sentCoins[0].Amount >= minFee {
			invites = int(sentCoins[0].Amount / minFee)
			if inviter == "" && invites > 0 {
				invites -= 1
			}
		}
	}
	// register.
	counter++
	user := &User{
		address: caller,
		name:    name,
		profile: profile,
		number:  counter,
		invites: invites,
		inviter: inviter,
	}
	name2User.Set(name, user)
	addr2User.Set(caller.String(), user)
}

func Invite(invitee string) {
	// assert CallTx call.
	std.AssertOriginCall()
	// get caller/inviter.
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	lines := strings.Split(invitee, "\n")
	if caller == admin {
		// nothing to do, all good
	} else {
		// ensure has invites.
		userI, ok := addr2User.Get(caller.String())
		if !ok {
			panic("user unknown")
		}
		user := userI.(*User)
		if user.invites <= 0 {
			panic("user has no invite tokens")
		}
		user.invites -= len(lines)
		if user.invites < 0 {
			panic("user has insufficient invite tokens")
		}
	}
	// for each line...
	for _, line := range lines {
		if line == "" {
			continue // file bodies have a trailing newline.
		} else if strings.HasPrefix(line, `//`) {
			continue // comment
		}
		// record invite.
		invitekey := string(caller) + ":" + string(line)
		invites.Set(invitekey, true)
	}
}

func GrantInvites(invites string) {
	// assert CallTx call.
	std.AssertOriginCall()
	// assert admin.
	caller := std.GetCallerAt(2)
	if caller != std.GetOrigCaller() {
		panic("should not happen") // because std.AssertOrigCall().
	}
	if caller != admin {
		panic("unauthorized")
	}
	// for each line...
	lines := strings.Split(invites, "\n")
	for _, line := range lines {
		if line == "" {
			continue // file bodies have a trailing newline.
		} else if strings.HasPrefix(line, `//`) {
			continue // comment
		}
		// parse name and invites.
		var name string
		var invites int
		parts := strings.Split(line, ":")
		if len(parts) == 1 { // short for :1.
			name = parts[0]
			invites = 1
		} else if len(parts) == 2 {
			name = parts[0]
			invites_, err := strconv.Atoi(parts[1])
			if err != nil {
				panic(err)
			}
			invites = int(invites_)
		} else {
			panic("should not happen")
		}
		// give invites.
		userI, ok := name2User.Get(name)
		if !ok {
			// maybe address.
			userI, ok = addr2User.Get(name)
			if !ok {
				panic("invalid user " + name)
			}
		}
		user := userI.(*User)
		user.invites += invites
	}
}

// Any leftover fees go toward invitations.
func SetMinFee(newMinFee int64) {
	// assert CallTx call.
	std.AssertOriginCall()
	// assert admin caller.
	caller := std.GetCallerAt(2)
	if caller != admin {
		panic("unauthorized")
	}
	// update global variables.
	minFee = newMinFee
}

// This helps prevent fat finger accidents.
func SetMaxFeeMultiple(newMaxFeeMult int64) {
	// assert CallTx call.
	std.AssertOriginCall()
	// assert admin caller.
	caller := std.GetCallerAt(2)
	if caller != admin {
		panic("unauthorized")
	}
	// update global variables.
	maxFeeMult = newMaxFeeMult
}

//----------------------------------------
// Exposed public functions

func GetUserByName(name string) *User {
	userI, ok := name2User.Get(name)
	if !ok {
		return nil
	}
	return userI.(*User)
}

func GetUserByAddress(addr std.Address) *User {
	userI, ok := addr2User.Get(addr.String())
	if !ok {
		return nil
	}
	return userI.(*User)
}


//----------------------------------------
// Constants

// NOTE: name length must be clearly distinguishable from a bech32 address.
var reName = regexp.MustCompile(`^[a-z]+[_a-z0-9]{5,16}$`)

//----------------------------------------
// Render main page

func Render(path string) string {
	if path == "" {
		return renderHome()
	} else if len(path) >= 38 { // 39? 40?
		if path[:2] != "g1" {
			return "invalid address " + path
		}
		user := GetUserByAddress(std.Address(path))
		if user == nil {
			// TODO: display basic information about account.
			return "unknown address " + path
		}
		return user.Render()
	} else {
		user := GetUserByName(path)
		if user == nil {
			return "unknown username " + path
		}
		return user.Render()
	}
}

func renderHome() string {
	doc := ""
	name2User.Iterate("", "", func(key string, value interface{}) bool {
		user := value.(*User)
		doc += " * [" + user.name + "](/r/demo/users:" + user.name + ")\n"
		return false
	})
	return doc
}
