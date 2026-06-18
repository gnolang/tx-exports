package social

import (
	"strconv"
	"strings"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"
)

//----------------------------------------
// private utility methods

// Get the UserPosts for the user.
func getUserPosts(userAddr address) *UserPosts {
	userPosts, exists := gUserPostsByAddress.Get(userAddr.String())
	if !exists {
		return nil
	}

	return userPosts.(*UserPosts)
}

// Get the UserPosts for the userAddr. If not found, add a new UserPosts to
// gUserPostsByAddress and update gUserAddressByName with the username.
// (The caller usually has already called usernameOf to get the username, but if
// it is "" then this will get it.)
func getOrCreateUserPosts(userAddr address, username string) *UserPosts {
	userPosts := getUserPosts(userAddr)
	if userPosts != nil {
		return userPosts
	}

	if username == "" {
		username = usernameOf(userAddr)
	}
	if username == "" {
		username = userAddr.String()
	}

	userPosts = newUserPosts(gRealmPath+":"+username, userAddr)
	gUserPostsByAddress.Set(userAddr.String(), userPosts)
	gUserAddressByName.Set(username, userAddr)

	return userPosts
}

func padZero(u64 uint64, length int) string {
	str := strconv.Itoa(int(u64))
	if len(str) >= length {
		return str
	} else {
		return strings.Repeat("0", length-len(str)) + str
	}
}

func postIDKey(pid PostID) string {
	return padZero(uint64(pid), 10)
}

func reactionKey(reaction Reaction) string {
	return strconv.Itoa(int(reaction))
}

// If reactions has an value for the given reaction, then return it.
// Otherwise, add the reaction key to reactions, set the value to an empty bptree.BPTree and return it.
func getOrCreateReactionValue(reactions *bptree.BPTree, reaction Reaction) *bptree.BPTree {
	key := reactionKey(reaction)
	valueI, exists := reactions.Get(key)
	if exists {
		return valueI.(*bptree.BPTree)
	} else {
		value := bptree.NewBPTree32()
		reactions.Set(key, value)
		return value
	}
}

// listByteStringKeysByPrefix returns up to maxResults keys from tree that start
// with the given prefix, treating keys as byte strings (not Unicode runes).
// Inlined from gno.land/p/jefft0/avlhelpers which is not yet deployed.
func listByteStringKeysByPrefix(tree bptree.ITree, prefix string, maxResults int) []string {
	result := []string{}
	end := ""
	n := len(prefix)
	for n > 0 {
		if ascii := int(prefix[n-1]); ascii < 0xff {
			end = prefix[0:n-1] + string(ascii+1)
			break
		}
		n--
	}
	tree.Iterate(prefix, end, func(key string, value any) bool {
		result = append(result, key)
		return len(result) >= maxResults
	})
	return result
}

func indentBody(indent string, body string) string {
	lines := strings.Split(body, "\n")
	res := ""
	for i, line := range lines {
		if i > 0 {
			res += "\n"
		}
		res += indent + line
	}
	return res
}

// NOTE: length must be greater than 3.
func summaryOf(str string, length int) string {
	lines := strings.SplitN(str, "\n", 2)
	line := lines[0]
	if len(line) > length {
		line = line[:(length-3)] + "..."
	} else if len(lines) > 1 {
		// len(line) <= 80
		line = line + "..."
	}
	return line
}

func displayAddressMD(addr address) string {
	user := users.ResolveAddress(addr)
	if user == nil {
		return "[" + addr.String() + "](/r/gnoland/users/v1:" + addr.String() + ")"
	} else {
		return "[@" + user.Name() + "](" + gRealmPath + ":" + user.Name() + ")"
	}
}

func usernameOf(addr address) string {
	user := users.ResolveAddress(addr)
	if user == nil {
		return ""
	} else {
		return user.Name()
	}
}

// Return the User info as a JSON string.
// (This is a temporary utility until gno.land supports returning structured data directly.)
func marshalJsonUser(user *users.UserData) string {
	return ufmt.Sprintf(
		"{\"address\": \"%s\", \"name\": \"%s\", \"deleted\": %t}",
		user.Addr().String(), user.Name(), user.IsDeleted())
}
