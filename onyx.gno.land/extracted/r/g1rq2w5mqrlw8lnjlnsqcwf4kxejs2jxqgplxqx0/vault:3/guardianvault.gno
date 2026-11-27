package vault

// VaultState is the lifecycle state of a vault.
//
//	ACTIVE ──RequestRecovery──▶ RECOVERING ──Execute──▶ ACTIVE
//	   ▲                             │
//	   └──────CancelRecovery─────────┘
type VaultState int

const (
	// ACTIVE means the vault is under the owner's control.
	ACTIVE VaultState = iota

	// RECOVERING means a recovery request is open; configuration and
	// withdrawals are frozen until it is executed or cancelled.
	RECOVERING
)

// Parameter bounds.
const (
	// MinWindowSecs is the shortest accepted recovery window: one hour.
	MinWindowSecs = int64(3600)

	// MaxWindowSecs is the longest accepted recovery window: thirty days.
	MaxWindowSecs = int64(2592000)

	// MaxGuardians is the largest accepted guardian set.
	MaxGuardians = 10
)

// Vault holds the full state of one vault.
//
// Balance is tracked internally because every vault shares the same realm
// address, so a banker lookup can only return the aggregate.
type Vault struct {
	// ID is the vault identifier, equal to its index in vaults.
	ID int

	// Owner is the address allowed to configure the vault and withdraw funds.
	Owner address

	// BackupAddr receives the balance and the ownership on a completed recovery.
	BackupAddr address

	// Guardians are the addresses eligible to vote on a recovery.
	Guardians []address

	// Threshold is the number of votes required to execute a recovery.
	Threshold int

	// WindowSecs is the recovery window length in seconds.
	WindowSecs int64

	// Balance is this vault's share of the realm balance, in ugnot.
	Balance int64

	// State is the current lifecycle state.
	State VaultState

	// Requestor is the address that opened the current recovery.
	Requestor address

	// RequestedAt is the unix timestamp at which the current recovery started.
	RequestedAt int64

	// Votes holds the addresses that have voted in the current recovery.
	Votes []address

	// RecoveryCount is the number of completed recoveries.
	RecoveryCount int

	// LastRecoveredAt is the unix timestamp of the last completed recovery.
	LastRecoveredAt int64
}

// vaults holds every vault. The index equals the ID and entries are never removed.
var vaults []*Vault

// mustGet returns the vault with the given ID.
//
// Parameters:
//   - id: Vault identifier.
//
// Returns:
//   - *Vault: The matching vault. Panics if id is out of range.
func mustGet(id int) *Vault {
	if id < 0 || id >= len(vaults) {
		panic("no such vault")
	}
	return vaults[id]
}

// requireOwner asserts that the caller is the owner of v.
//
// Parameters:
//   - cur: Realm context; the caller is read from cur.Previous().
//   - v: Vault to check. Panics if the caller is not the owner.
func requireOwner(cur realm, v *Vault) {
	if cur.Previous().Address() != v.Owner {
		panic("caller is not the owner")
	}
}

// isGuardian reports whether addr is in the guardian set.
//
// Parameters:
//   - addr: Address to look up.
//
// Returns:
//   - bool: True if addr is a guardian.
func (v *Vault) isGuardian(addr address) bool {
	for _, g := range v.Guardians {
		if g == addr {
			return true
		}
	}
	return false
}

// hasVoted reports whether addr has already voted in the current recovery.
//
// Parameters:
//   - addr: Address to look up.
//
// Returns:
//   - bool: True if addr has voted.
func (v *Vault) hasVoted(addr address) bool {
	for _, a := range v.Votes {
		if a == addr {
			return true
		}
	}
	return false
}

// validateGuardians validates the guardian set and the vote threshold.
//
// Parameters:
//   - guardians: Guardian addresses; 1..MaxGuardians unique non-zero addresses.
//   - threshold: Votes required for a recovery; within 1..len(guardians).
func validateGuardians(guardians []address, threshold int) {
	n := len(guardians)
	if n < 1 || n > MaxGuardians {
		panic("guardian count must be 1..10")
	}
	if threshold < 1 || threshold > n {
		panic("threshold must be within 1..len(guardians)")
	}
	for i := 0; i < n; i++ {
		if guardians[i] == address("") {
			panic("guardian must not be zero address")
		}
		for j := i + 1; j < n; j++ {
			if guardians[i] == guardians[j] {
				panic("duplicate guardian address")
			}
		}
	}
}

// validateWindow validates the recovery window length.
//
// Parameters:
//   - windowSecs: Window in seconds; within MinWindowSecs..MaxWindowSecs.
func validateWindow(windowSecs int64) {
	if windowSecs < MinWindowSecs || windowSecs > MaxWindowSecs {
		panic("windowSecs must be within 3600..2592000")
	}
}
