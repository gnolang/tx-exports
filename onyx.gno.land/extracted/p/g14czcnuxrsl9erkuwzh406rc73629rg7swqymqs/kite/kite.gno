// Package kite encodes Kite transfers and derives the address each one is paid into.
package kite

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
)

const (
	Version = "kite1"
	Native  = "ugnot"
	MaxFees = 10
	MaxHops = 3
)

type Fee struct {
	Recipient address
	Amount    int64
}

// Transfer is paid in Token and settled in Settle. When they differ, Route is the
// GnoSwap route from one to the other, and MinOut the least the swap may return.
type Transfer struct {
	ID        string
	Token     string
	Amount    int64
	Settle    string
	MinOut    int64
	Route     string
	Recipient address
	Fees      []Fee
	Refund    address
	ExpiresAt int64
}

func (t Transfer) Encode() string {
	fees := make([]string, len(t.Fees))
	for i, f := range t.Fees {
		fees[i] = f.Recipient.String() + ":" + strconv.FormatInt(f.Amount, 10)
	}
	return strings.Join([]string{
		Version,
		"id=" + t.ID,
		"token=" + t.Token,
		"amount=" + strconv.FormatInt(t.Amount, 10),
		"settle=" + t.Settle,
		"min_out=" + strconv.FormatInt(t.MinOut, 10),
		"route=" + t.Route,
		"recipient=" + t.Recipient.String(),
		"fees=" + strings.Join(fees, ","),
		"refund=" + t.Refund.String(),
		"expires=" + strconv.FormatInt(t.ExpiresAt, 10),
	}, ";")
}

// Decode parses a transfer and accepts only its canonical encoding, so a transfer has one hash.
func Decode(s string) (Transfer, error) {
	parts := strings.Split(s, ";")
	keys := []string{"id", "token", "amount", "settle", "min_out", "route", "recipient", "fees", "refund", "expires"}
	if len(parts) != len(keys)+1 || parts[0] != Version {
		return Transfer{}, errors.New("malformed transfer")
	}
	v := map[string]string{}
	for i, key := range keys {
		if !strings.HasPrefix(parts[i+1], key+"=") {
			return Transfer{}, errors.New("malformed transfer")
		}
		v[key] = parts[i+1][len(key)+1:]
	}

	t := Transfer{
		ID:        v["id"],
		Token:     v["token"],
		Settle:    v["settle"],
		Route:     v["route"],
		Recipient: address(v["recipient"]),
		Refund:    address(v["refund"]),
	}
	var err error
	if t.Amount, err = strconv.ParseInt(v["amount"], 10, 64); err != nil {
		return Transfer{}, errors.New("invalid amount")
	}
	if t.MinOut, err = strconv.ParseInt(v["min_out"], 10, 64); err != nil {
		return Transfer{}, errors.New("invalid min_out")
	}
	if t.ExpiresAt, err = strconv.ParseInt(v["expires"], 10, 64); err != nil {
		return Transfer{}, errors.New("invalid expiry")
	}
	if v["fees"] != "" {
		for _, item := range strings.Split(v["fees"], ",") {
			pair := strings.Split(item, ":")
			if len(pair) != 2 {
				return Transfer{}, errors.New("invalid fee")
			}
			amount, err := strconv.ParseInt(pair[1], 10, 64)
			if err != nil {
				return Transfer{}, errors.New("invalid fee")
			}
			t.Fees = append(t.Fees, Fee{address(pair[0]), amount})
		}
	}

	if err := t.Validate(); err != nil {
		return Transfer{}, err
	}
	if t.Encode() != s {
		return Transfer{}, errors.New("transfer is not canonical")
	}
	return t, nil
}

func (t Transfer) Validate() error {
	if !isHex(t.ID, 32) || strings.Trim(t.ID, "0") == "" {
		return errors.New("invalid id")
	}
	if !IsToken(t.Token) || !IsToken(t.Settle) {
		return errors.New("invalid token")
	}
	if t.Amount <= 0 || t.MinOut <= 0 {
		return errors.New("invalid amount")
	}
	if t.Token == t.Settle {
		if t.Route != "" || t.MinOut != t.Amount {
			return errors.New("a transfer in the settlement token has no swap")
		}
	} else if err := validateRoute(t.Route, t.Token, t.Settle); err != nil {
		return err
	}
	if !t.Recipient.IsValid() || !t.Refund.IsValid() {
		return errors.New("invalid address")
	}
	if t.ExpiresAt <= 0 {
		return errors.New("invalid expiry")
	}
	if len(t.Fees) > MaxFees {
		return errors.New("too many fees")
	}
	var total int64
	for _, f := range t.Fees {
		if f.Amount <= 0 || !f.Recipient.IsValid() {
			return errors.New("invalid fee")
		}
		total += f.Amount
		if total > t.MinOut {
			return errors.New("fees exceed min_out")
		}
	}
	return nil
}

// validateRoute checks a GnoSwap route, "in:out:fee" hops joined by "*POOL*",
// from one GRC20 to another: a realm can't wrap or unwrap GNOT.
func validateRoute(route, from, to string) error {
	hops := strings.Split(route, "*POOL*")
	if from == Native || to == Native || len(hops) > MaxHops {
		return errors.New("invalid swap route")
	}
	next := from
	for _, hop := range hops {
		parts := strings.Split(hop, ":")
		if len(parts) != 3 || parts[0] != next || !IsToken(parts[1]) || parts[1] == Native ||
			!(parts[2] == "100" || parts[2] == "500" || parts[2] == "3000" || parts[2] == "10000") {
			return errors.New("invalid swap route")
		}
		next = parts[1]
	}
	if next != to {
		return errors.New("invalid swap route")
	}
	return nil
}

func (t Transfer) TotalFees() int64 {
	var total int64
	for _, f := range t.Fees {
		total += f.Amount
	}
	return total
}

func (t Transfer) Hash() string {
	sum := sha256.Sum256([]byte(t.Encode()))
	return hex.EncodeToString(sum[:])
}

func (t Transfer) Subpath() string {
	return Subpath(t.Hash())
}

func (t Transfer) DepositAddress(realmPath string) address {
	return chain.DerivePkgSubAddr(realmPath, t.Subpath())
}

func Subpath(hash string) string {
	return "t/" + hash
}

// IsToken accepts ugnot or a grc20reg key, <realm path>.<symbol>.
func IsToken(token string) bool {
	if token == Native {
		return true
	}
	dot := strings.LastIndex(token, ".")
	return strings.HasPrefix(token, "gno.land/r/") && dot > strings.LastIndex(token, "/") &&
		dot < len(token)-1 && !strings.ContainsAny(token, ";=,:* ")
}

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
