package whitelist

import (
	"std"
)

type Whitelist struct {
	name     string         // Name of whitelist
	owner    std.Address    // Owner of whitelist
	deadline int          // Whitelist deadline in block height
	maxUsers int            // Max number of users in whitelist
	userList []std.Address  // Currently signed-up users
}

// Create a new Whitelist instance from arguments
func NewWhitelist(name string, deadline int, maxUsers int, owner std.Address) *Whitelist {
	return &Whitelist{
		name:     name,
		owner:    owner,
		deadline: deadline,
		maxUsers: maxUsers,
		userList: make([]std.Address, 0),
	}
}

func (w *Whitelist) GetWhitelistName() string {
	return w.name
}

func (w *Whitelist) GetWhitelistOwner() std.Address {
	return w.owner
}

func (w *Whitelist) GetWhitelistDeadline() int {
	return w.deadline
}

func (w *Whitelist) GetMaxUsers() int {
	return w.maxUsers
}

func (w *Whitelist) GetWhitelistedUsers() []std.Address {
	return w.userList
}

func (w *Whitelist) AddUserToList(userToAdd std.Address) bool {
	w.userList = append(w.userList, userToAdd)
	return true
}

// Check if userToCheck is on whitelist w
func (w *Whitelist) IsOnWhitelist(userToCheck std.Address) bool {
	for _, user := range w.GetWhitelistedUsers() {
		if user.String() == userToCheck.String() {
			return true
		}
	}
	return false
}

// Check if txSender is owner of w
func (w *Whitelist) IsOwnerOfWhitelist(txSender std.Address) bool {
	return txSender == w.GetWhitelistOwner()
}