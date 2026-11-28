// Package budget implements the value-only accounting used by Shared Budget.
package budget

import (
	"crypto/bech32"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	Denom          = "ugnot"
	Maintenance    = "maintenance"
	Reimbursements = "reimbursements"
	Refund         = "refund"
	maxInt64       = 1<<63 - 1
)

type Ledger struct {
	Funded    int64
	Available int64
	Reserved  int64
	Claimable int64
	Paid      int64
}

func Add(a, b int64) int64 {
	if a < 0 || b < 0 || a > maxInt64-b {
		panic("amount or height overflow")
	}
	return a + b
}

func Subtract(a, b int64) int64 {
	if b < 0 || a < b {
		panic("amount underflow")
	}
	return a - b
}

func RequirePositive(amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
}

func (l Ledger) Fund(amount int64) Ledger {
	RequirePositive(amount)
	l.Funded = Add(l.Funded, amount)
	l.Available = Add(l.Available, amount)
	return l
}

func (l Ledger) Reserve(amount int64) Ledger {
	RequirePositive(amount)
	l.Available = Subtract(l.Available, amount)
	l.Reserved = Add(l.Reserved, amount)
	return l
}

func (l Ledger) Approve(amount int64) Ledger {
	RequirePositive(amount)
	l.Reserved = Subtract(l.Reserved, amount)
	l.Claimable = Add(l.Claimable, amount)
	return l
}

func (l Ledger) Release(amount int64) Ledger {
	RequirePositive(amount)
	l.Reserved = Subtract(l.Reserved, amount)
	l.Available = Add(l.Available, amount)
	return l
}

func (l Ledger) RefundAvailable() Ledger {
	l.Claimable = Add(l.Claimable, l.Available)
	l.Available = 0
	return l
}

func (l Ledger) Pay(amount int64) Ledger {
	RequirePositive(amount)
	l.Claimable = Subtract(l.Claimable, amount)
	l.Paid = Add(l.Paid, amount)
	return l
}

func PeriodAt(height, start, periodBlocks int64) int64 {
	if start < 0 || height < start || periodBlocks <= 0 {
		panic("invalid period")
	}
	return (height - start) / periodBlocks
}

func CheckDeadline(height, deadline, maxHold int64) {
	if height < 0 || deadline <= height || deadline-height > maxHold {
		panic("deadline outside reservation window")
	}
}

func RequireAddress(addr address) {
	s := string(addr)
	if len(s) != 40 || !strings.HasPrefix(s, "g1") {
		panic("invalid Gno address")
	}
	hrp, data, version, err := bech32.DecodeGeneric(s)
	if err != nil || hrp != "g" || len(data) != 32 || version != bech32.Version0 {
		panic("invalid Gno address")
	}
}

func RequireDigest(digest string) {
	if len(digest) != 64 || strings.ToLower(digest) != digest {
		panic("evidence must be a lowercase SHA-256 digest")
	}
	if _, err := hex.DecodeString(digest); err != nil {
		panic("evidence must be a lowercase SHA-256 digest")
	}
}

// EvidenceCommitment binds a salted proof digest to its program and item.
func EvidenceCommitment(programID int64, lane string, itemID int64, proofDigest string) string {
	RequireDigest(proofDigest)
	payload := "shared-budget/v1\n" + strconv.FormatInt(programID, 10) + "\n" +
		lane + "\n" + strconv.FormatInt(itemID, 10) + "\n" + proofDigest + "\n"
	hash := sha256.Sum256([]byte(payload))
	return hex.EncodeToString(hash[:])
}

// ParsePolicyViewPath reads programID or programID/itemID for policy renders.
func ParsePolicyViewPath(path string) (int64, int64) {
	parts := strings.SplitN(path, "/", 3)
	programID, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || programID <= 0 {
		return 0, 0
	}
	if len(parts) == 1 {
		return programID, 0
	}
	itemID, err := strconv.ParseInt(parts[1], 10, 64)
	if len(parts) != 2 || err != nil || itemID <= 0 {
		return 0, 0
	}
	return programID, itemID
}
