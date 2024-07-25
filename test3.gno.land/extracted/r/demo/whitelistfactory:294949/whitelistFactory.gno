package whitelistfactory

import (
	"bytes"
	"std"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/ufmt"
	"gno.land/p/demo/whitelist"
)

// State variables
var (
	whitelistTree *avl.Tree
)

func NewWhitelist(name string, deadline int, maxUsers int64) (int, string) {

	// Check if deadline is in the past
	if deadline <= std.GetHeight() {
		return -1, "deadline cannot be in the past"
	}

	// Get user who sent the transaction
	txSender := std.GetOrigCaller()

	// We will use the current size of the tree for the ID
	id := whitelistTree.Size()

	if maxUsers <= 0 {
		return -1, "Maximum number of users cannot be less than 1"
	}

	// Create new whitelist instance
	w := whitelist.NewWhitelist(name, deadline, maxUsers, txSender)

	// Update AVL tree with new state
	success := whitelistTree.Set(strconv.Itoa(id), w)
    if success {
	    return id, "successfully created whitelist!"
    }
    return -1, "could not create new whitelist"
}

func SignUpToWhitelist(whitelistID int) string {
	// Get ID and convert to string
	id := strconv.Atoi(whitelistID)
	
	// Get txSender
	txSender := std.GetOrigCaller()

	// Try to get specific whitelist from AVL tree
	// Note: AVL tree keys are of the string type
	whiteListRaw, exists := whitelistTree.Get(id)

	if !exists {
		return "whitelist does not exist"
	}

	// Cast raw Tree data into "Whitelist" type
	w, _ := whiteListRaw.(*whitelist.Whitelist)

	ddl := w.GetWhitelistDeadline()

	// error handling
	if w.IsOnWhitelist(txSender) {
		return "user already in whitelist"
	}

	// If deadline has passed
	if ddl <= std.GetHeight() {
		return "whitelist already closed"
	}

	// If whitelist is full
	if w.GetMaxUsers() <= len(w.GetWhitelistedUsers()) {
		return "whitelist full"
	}

	// Add txSender to user list
	w.AddUserToList(txSender)

	// Update the AVL tree with new state
	success := whitelistTree.Set(id, w)
	if success {
	    return ufmt.Sprintf("successfully added user to whitelist %d", whitelistID)
	}
    return "failed to sign up"
}

func Render(path string) string {
	if path == "" {
		return renderHomepage()
	}

	return "unknown page"
}

func renderHomepage() string {

	// Define empty buffer
	var b bytes.Buffer

	b.WriteString("# Sign up to a Whitelist\n\n")

	// If no whitelists have been created
	if whitelistTree.Size() == 0 {
		b.WriteString("### No whitelists available currently!")
		return b.String()
	}

	// Iterate through AVL tree
	whitelistTree.Iterate("", "", func(key string, value interface{}) bool {

		// cast raw data from tree into Whitelist struct
		w := value.(*whitelist.Whitelist)
		ddl := w.GetWhitelistDeadline()

		// Add whitelist name
		b.WriteString(
			ufmt.Sprintf(
				"## Whitelist #%s: %s\n",
				key, // whitelist ID
				w.GetWhitelistName(),
			),
		)

		// Check if whitelist deadline is past due
		if ddl > std.GetHeight() {
			b.WriteString(
				ufmt.Sprintf(
					"Whitelist sign-ups close at block %d\n",
					w.GetWhitelistDeadline(),
				),
			)
		} else {
			b.WriteString(
				ufmt.Sprintf(
					"Whitelist sign-ups closed!\n\n",
				),
			)
		}

		// List max number of users in waitlist
		b.WriteString(
			ufmt.Sprintf(
				"Maximum number of users in whitelist: %d\n\n",
				w.GetMaxUsers(),
			),
		)

		// List all users that are currently whitelisted
		if users := w.GetWhitelistedUsers(); len(users) > 0 {
			b.WriteString(
				ufmt.Sprintf("Currently whitelisted users: %d\n\n", len(users)),
			)

			for index, user := range users {
				b.WriteString(
					ufmt.Sprintf("#%d - %s  \n", index, user),
				)
			}
		} else {
			b.WriteString("No addresses are whitelisted currently\n")
		}

		b.WriteString("\n")
		return false
	})

	return b.String()
}