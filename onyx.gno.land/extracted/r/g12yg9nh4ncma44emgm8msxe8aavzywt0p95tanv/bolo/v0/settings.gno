package bolo

import "gno.land/p/nt/avl/v0"

// Phase 0's values (API §2.2): placeholders for the deposit, the minimum donation and
// the escrow cap, whose launch values API §2.2 proposes, and the three durations it
// proposes. All are settled before Phase 1 (README), and only the admin changes them
// afterwards.
const (
	launchDeposit     int64 = 1_000_000 // ugnot
	launchDormancy    int64 = 90 * secondsPerDay
	launchExitDelay   int64 = 60 * secondsPerDay
	launchBondHold    int64 = 30 * secondsPerDay
	launchMinDonation int64 = 1_000_000     // ugnot, a placeholder
	launchEscrowCap   int64 = 1_000_000_000 // ugnot (1,000 GNOT), a placeholder

	// maxCategories keeps the list GetSettings returns to one bounded read (INV-9).
	maxCategories = 50
)

// The admin and the settings only it changes (API §2.2, §3.6). Package state, all
// unexported (C6).
var (
	admin        address = adminAddr // a realm once a DAO accepts the role (ADR D11)
	pendingAdmin address             // the proposed admin until it accepts; "" for none

	params = Params{ // for campaigns created from now on (INV-5)
		CreationDeposit: launchDeposit,
		DormancyPeriod:  launchDormancy,
		ExitDelay:       launchExitDelay,
		BondHold:        launchBondHold,
	}

	presets              = [4]int64{5_000_000, 10_000_000, 20_000_000, 50_000_000}
	minDonation          = launchMinDonation
	escrowCap            = launchEscrowCap // 0: no cap
	tipRecipient address = adminAddr
	paused       bool
	sunset       bool

	// The categories: a tree to look one up, and the codes in the order they were
	// added, for GetSettings. init fills the tree from the launch set (API §2.1).
	categories    avl.Tree // code → true
	categoryOrder = []string{
		"medical", "emergency", "disaster", "humanitarian", "water", "food",
		"education", "orphans", "animals", "funeral", "worship", "community",
		"sport", "celebration", "personal", "other",
	}
)

// SettingsView is the live settings (API §2.4): a copy, holding nothing of the
// realm's state.
type SettingsView struct {
	Version          string // "v0"
	Presets          [4]int64
	MaxEscrowBalance int64 // 0 = no cap
	Categories       []string
	TipRecipient     address
	MinDonation      int64
	Paused, Sunset   bool
}

// GetParams returns the Params a campaign created now would get (API §4).
func GetParams() Params { return params }

// GetSettings returns the live settings (API §4).
func GetSettings() SettingsView {
	return SettingsView{
		Version:          "v0",
		Presets:          presets,
		MaxEscrowBalance: escrowCap,
		Categories:       append([]string(nil), categoryOrder...),
		TipRecipient:     tipRecipient,
		MinDonation:      minDonation,
		Paused:           paused,
		Sunset:           sunset,
	}
}

// GetAdmin returns the admin and the proposed admin, "" when there is none (API §4).
func GetAdmin() (address, address) { return admin, pendingAdmin }
