package vault

import "time"

// This file contains every exported crossing function and is the only place
// where authorization is decided. Each function verifies cur.IsCurrent() first,
// derives the caller from cur.Previous().Address(), and validates every
// precondition before the first state write.

// CreateVault creates a vault and registers the caller as its owner.
//
// Parameters:
//   - cur: Realm context.
//   - threshold: Votes required to execute a recovery; within 1..len(guardians).
//   - backup: Address that receives the funds and the ownership on recovery.
//   - windowSecs: Recovery window in seconds; within 3600..2592000.
//   - guardians: Guardian addresses; 1..10 unique, non-zero addresses. The
//     variadic form is required because MsgCall cannot encode []address.
//
// Returns:
//   - int: ID of the new vault.
func CreateVault(cur realm, threshold int, backup address, windowSecs int64, guardians ...address) int {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}

	owner := cur.Previous().Address()
	if owner == address("") {
		panic("owner must not be zero address")
	}
	validateGuardians(guardians, threshold)
	if backup == address("") {
		panic("backup address must not be zero")
	}
	validateWindow(windowSecs)

	// Copy the input so the caller cannot mutate the underlying array afterwards.
	g := make([]address, len(guardians))
	copy(g, guardians)

	id := len(vaults)
	vaults = append(vaults, &Vault{
		ID:         id,
		Owner:      owner,
		BackupAddr: backup,
		Guardians:  g,
		Threshold:  threshold,
		WindowSecs: windowSecs,
		State:      ACTIVE,
	})
	return id
}

// Deposit credits the ugnot attached to the current transaction to a vault.
// The amount is read from the transaction envelope, never from a parameter.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
func Deposit(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	amt := receivedUgnot(cur)
	if amt <= 0 {
		panic("no ugnot sent")
	}
	v.Balance += amt
}

// Withdraw sends ugnot from a vault to an arbitrary address. Owner only, and
// only while the vault is ACTIVE.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
//   - to: Recipient address; must be non-zero.
//   - amount: Amount in ugnot; must be positive and not exceed the balance.
func Withdraw(cur realm, id int, to address, amount int64) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if to == address("") {
		panic("recipient must not be zero address")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	if amount > v.Balance {
		panic("insufficient balance")
	}

	// Debit before paying: a panic in payUgnot rolls back the whole transaction,
	// so no half-written state can survive.
	v.Balance -= amount
	payUgnot(cur, to, amount)
}

// AddGuardian appends a guardian to the set without changing the threshold.
// Owner only, and only while the vault is ACTIVE.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
//   - guardian: Address to append; must be non-zero, not already present, and
//     the set must stay within MaxGuardians.
func AddGuardian(cur realm, id int, guardian address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if guardian == address("") {
		panic("guardian must not be zero address")
	}
	if v.isGuardian(guardian) {
		panic("already a guardian")
	}
	if len(v.Guardians) >= MaxGuardians {
		panic("guardian count would exceed 10")
	}

	v.Guardians = append(v.Guardians, guardian)
}

// SetGuardians replaces the whole guardian set and the threshold. Owner only,
// and only while the vault is ACTIVE. Removing a guardian is possible only
// through this function, so the threshold is always submitted with the set.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
//   - threshold: Votes required to execute a recovery; within 1..len(guardians).
//   - guardians: Guardian addresses; 1..10 unique, non-zero addresses.
func SetGuardians(cur realm, id int, threshold int, guardians ...address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	validateGuardians(guardians, threshold)

	g := make([]address, len(guardians))
	copy(g, guardians)
	v.Guardians = g
	v.Threshold = threshold
}

// SetBackup replaces the backup address. Owner only, and only while the vault
// is ACTIVE: the destination is frozen for the duration of a recovery.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
//   - backup: New backup address; must be non-zero.
func SetBackup(cur realm, id int, backup address) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != ACTIVE {
		panic("vault is not active")
	}
	if backup == address("") {
		panic("backup address must not be zero")
	}
	v.BackupAddr = backup
}

// RequestRecovery switches a vault to RECOVERING and starts the window.
// Callable by anyone; the requestor gains no voting power.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
func RequestRecovery(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != ACTIVE {
		panic("vault is not active")
	}

	v.State = RECOVERING
	v.Requestor = cur.Previous().Address()
	v.RequestedAt = time.Now().Unix()
	v.Votes = nil
}

// Vote records one vote from a guardian. Each guardian may vote once and the
// vote count never exceeds the threshold.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
func Vote(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}

	caller := cur.Previous().Address()
	if !v.isGuardian(caller) {
		panic("not a guardian")
	}
	if v.hasVoted(caller) {
		panic("already voted")
	}
	if len(v.Votes) >= v.Threshold {
		panic("enough votes already")
	}

	v.Votes = append(v.Votes, caller)
}

// CancelRecovery cancels an open recovery, clears the votes and returns the
// vault to ACTIVE. Owner only, and only while the vault is RECOVERING.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
func CancelRecovery(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)
	requireOwner(cur, v)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}

	v.State = ACTIVE
	v.Votes = nil
	v.Requestor = address("")
	v.RequestedAt = 0
}

// Execute pays the balance to the backup address, transfers the ownership to
// it, and resets the guardian configuration. Callable by anyone once the
// threshold is met and the recovery window has elapsed.
//
// Parameters:
//   - cur: Realm context.
//   - id: Vault identifier.
func Execute(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	v := mustGet(id)

	if v.State != RECOVERING {
		panic("vault not recovering")
	}
	if len(v.Votes) < v.Threshold {
		panic("threshold not reached")
	}

	now := time.Now().Unix()
	if now < v.RequestedAt+v.WindowSecs {
		panic("recovery window has not elapsed")
	}

	amt := v.Balance
	v.Balance = 0
	// Skip the banker on a zero balance: a zero-value transfer is meaningless
	// and some implementations reject it.
	if amt > 0 {
		payUgnot(cur, v.BackupAddr, amt)
	}

	v.Owner = v.BackupAddr
	v.Guardians = nil
	v.Threshold = 0
	v.Votes = nil
	v.Requestor = address("")
	v.RequestedAt = 0
	v.State = ACTIVE

	v.RecoveryCount++
	v.LastRecoveredAt = now
}
