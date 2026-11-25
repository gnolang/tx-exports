// Package trickle is a payment-streaming realm: lock GNOT once and it
// unlocks for the recipient every second. The recipient withdraws what has
// unlocked whenever they like; the sender can cancel and take back only what
// has not unlocked yet.
//
// Use cases: salaries, grants, vesting with a cliff, subscriptions, escrowed
// freelance work. The schedule math lives in gno.land/p/g1a04glq8w6ts7r9yzyznpa99qkzwp8pewcf3aef/trickle
// and is reusable by any realm.
package trickle

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"crypto/bech32"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/g1a04glq8w6ts7r9yzyznpa99qkzwp8pewcf3aef/trickle"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	denom      = "ugnot"
	maxMemoLen = 80
	maxBatch   = 50
)

// Record is a stream plus the metadata the realm keeps about it.
type Record struct {
	trickle.Stream
	ID        uint64
	Memo      string
	CreatedAt int64
}

var (
	admin  address
	appURL string

	nextID      seqid.ID
	streams     = avl.NewTree() // seqid -> *Record
	bySender    = avl.NewTree() // addr + ":" + seqid -> nil
	byRecipient = avl.NewTree() // addr + ":" + seqid -> nil

	totalDeposited int64 // ugnot ever locked
	totalPaid      int64 // ugnot paid out to recipients
	totalRefunded  int64 // ugnot returned to senders
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

// Create opens a stream to recipient funded by the ugnot sent with the call.
//
//   - startAt: unix time the stream starts; 0 means now.
//   - cliffSeconds: nothing is withdrawable until this long after the start;
//     at the cliff, everything unlocked so far becomes available at once.
//   - durationSeconds: time from start until the deposit is fully unlocked.
//   - cancelable: whether the sender may cancel and reclaim the locked part.
//
// It returns the new stream ID. Must be called directly by a user
// (gnokey maketx call / a wallet) with -send <amount>ugnot.
func Create(cur realm, recipient address, startAt, cliffSeconds, durationSeconds int64, cancelable bool, memo string) uint64 {
	sender, sent := receivePayment(cur)
	now := time.Now().Unix()
	id := open(now, sender, recipient, sent, startAt, cliffSeconds, durationSeconds, cancelable, memo)
	return id
}

// CreateBatch opens one stream per "address:ugnot" pair in recipients
// (comma separated, at most 50), all on the same schedule: a payroll in a
// single transaction. The ugnot sent must equal the sum of the amounts.
// It returns the new stream IDs, comma separated.
func CreateBatch(cur realm, recipients string, startAt, cliffSeconds, durationSeconds int64, cancelable bool, memo string) string {
	sender, sent := receivePayment(cur)
	now := time.Now().Unix()

	parts := strings.Split(recipients, ",")
	if len(parts) > maxBatch {
		panic("too many recipients: at most " + strconv.Itoa(maxBatch))
	}
	var (
		ids []string
		sum int64
	)
	for _, part := range parts {
		addr, amountStr, ok := strings.Cut(strings.TrimSpace(part), ":")
		if !ok {
			panic(`recipients must look like "g1...:1000000,g1...:2500000"`)
		}
		amount, err := strconv.ParseInt(amountStr, 10, 64)
		if err != nil || amount <= 0 {
			panic("invalid amount for " + strconv.Quote(addr))
		}
		if amount > sent-sum {
			panic("amounts add up to more than the ugnot sent")
		}
		sum += amount
		id := open(now, sender, address(addr), amount, startAt, cliffSeconds, durationSeconds, cancelable, memo)
		ids = append(ids, strconv.FormatUint(id, 10))
	}
	if sum != sent {
		panic("amounts add up to less than the ugnot sent")
	}
	return strings.Join(ids, ",")
}

// Withdraw pays the caller, who must be the stream's recipient, amount ugnot
// out of what has unlocked. An amount of 0 withdraws everything available.
// It returns the amount paid.
func Withdraw(cur realm, id uint64, amount int64) int64 {
	r := mustGet(id)
	caller := cur.Previous().Address()
	if caller != r.Recipient {
		panic("only the recipient can withdraw")
	}
	paid, err := r.Withdraw(time.Now().Unix(), amount)
	if err != nil {
		panic(err)
	}
	totalPaid += paid
	pay(cur, r.Recipient, paid)
	chain.Emit("StreamWithdrawn",
		"id", strconv.FormatUint(id, 10),
		"recipient", r.Recipient.String(),
		"amount", strconv.FormatInt(paid, 10),
	)
	return paid
}

// Cancel stops a stream that has not ended: the recipient is paid everything
// unlocked so far and the sender is refunded the rest. The sender can cancel
// only a cancelable stream; the recipient can always walk away.
func Cancel(cur realm, id uint64) {
	r := mustGet(id)
	caller := cur.Previous().Address()
	now := time.Now().Unix()

	var (
		toRecipient, toSender int64
		err                   error
	)
	switch caller {
	case r.Sender:
		toRecipient, toSender, err = r.CancelBySender(now)
	case r.Recipient:
		toRecipient, toSender, err = r.Cancel(now)
	default:
		panic("only the sender or the recipient can cancel")
	}
	if err != nil {
		panic(err)
	}
	totalPaid += toRecipient
	totalRefunded += toSender
	pay(cur, r.Recipient, toRecipient)
	pay(cur, r.Sender, toSender)
	chain.Emit("StreamCanceled",
		"id", strconv.FormatUint(id, 10),
		"by", caller.String(),
		"toRecipient", strconv.FormatInt(toRecipient, 10),
		"toSender", strconv.FormatInt(toSender, 10),
	)
}

// Transfer hands the right to withdraw from a live stream to another
// address. Only the current recipient can call it.
func Transfer(cur realm, id uint64, to address) {
	r := mustGet(id)
	caller := cur.Previous().Address()
	if caller != r.Recipient {
		panic("only the recipient can transfer a stream")
	}
	mustBeCanonical(to)
	if to == r.Sender || to == r.Recipient {
		panic("new recipient must differ from the sender and the current recipient")
	}
	now := time.Now().Unix()
	if st := r.Status(now); st == trickle.Canceled || st == trickle.Settled {
		panic("stream is finished")
	}
	key := seqid.ID(id).String()
	byRecipient.Remove(r.Recipient.String() + ":" + key)
	byRecipient.Set(to.String()+":"+key, nil)
	r.Recipient = to
	chain.Emit("StreamTransferred",
		"id", strconv.FormatUint(id, 10),
		"from", caller.String(),
		"to", to.String(),
	)
}

// SetAppURL sets the web app link shown by Render. Admin only.
func SetAppURL(cur realm, url string) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !strings.HasPrefix(url, "https://") || len(url) > 200 || strings.ContainsAny(url, " ()[]<>\"'\n\r\t") {
		panic("invalid url")
	}
	appURL = url
}

// receivePayment returns the caller and the ugnot attached to the call.
//
// The two checks are a pair. unsafe.OriginSend() describes what the
// transaction attached, not what this realm received: only when the previous
// realm is a plain user call (no intermediate realm, no maketx run script)
// are those coins guaranteed to have landed at this realm's address.
func receivePayment(cur realm) (address, int64) {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by a user (maketx call)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount <= 0 {
		panic("send ugnot, and only ugnot, with the call to fund the stream")
	}
	return cur.Previous().Address(), sent[0].Amount
}

func open(now int64, sender, recipient address, amount, startAt, cliffSeconds, durationSeconds int64, cancelable bool, memo string) uint64 {
	if startAt == 0 {
		startAt = now
	}
	if startAt < now {
		panic("start time is in the past")
	}
	if cliffSeconds < 0 || durationSeconds <= 0 || durationSeconds > trickle.MaxDuration || cliffSeconds > durationSeconds {
		panic("need 0 <= cliffSeconds <= durationSeconds <= 100 years, and a positive duration")
	}
	if startAt > now+trickle.MaxDuration {
		panic("start time is too far in the future")
	}
	checkMemo(memo)
	mustBeCanonical(recipient)

	s, err := trickle.New(sender, recipient, amount, startAt, startAt+cliffSeconds, startAt+durationSeconds, cancelable)
	if err != nil {
		panic(err)
	}
	id := nextID.Next()
	key := id.String()
	streams.Set(key, &Record{Stream: s, ID: uint64(id), Memo: memo, CreatedAt: now})
	bySender.Set(sender.String()+":"+key, nil)
	byRecipient.Set(recipient.String()+":"+key, nil)
	totalDeposited += amount

	chain.Emit("StreamCreated",
		"id", strconv.FormatUint(uint64(id), 10),
		"sender", sender.String(),
		"recipient", recipient.String(),
		"amount", strconv.FormatInt(amount, 10),
		"start", strconv.FormatInt(s.Start, 10),
		"cliff", strconv.FormatInt(s.Cliff, 10),
		"end", strconv.FormatInt(s.End, 10),
	)
	return uint64(id)
}

// mustBeCanonical rejects any spelling of an address other than the one the
// chain reports for a caller. IsValid also accepts an all-uppercase or
// Bech32m spelling, and a stream stored under one of those could never be
// withdrawn, because Withdraw compares against the caller's canonical address.
func mustBeCanonical(a address) {
	if a.IsValid() {
		if hrp, data, err := bech32.DecodeNoLimit(a.String()); err == nil {
			if enc, err := bech32.Encode(hrp, data); err == nil && enc == a.String() {
				return
			}
		}
	}
	panic("invalid address: use the lowercase g1... form")
}

func checkMemo(memo string) {
	if len(memo) > maxMemoLen || !utf8.ValidString(memo) {
		panic("memo must be valid UTF-8 of at most " + strconv.Itoa(maxMemoLen) + " bytes")
	}
	for _, c := range memo {
		if c < 0x20 || c == 0x7f {
			panic("memo must not contain control characters")
		}
	}
}

func pay(cur realm, to address, amount int64) {
	if amount == 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(denom, amount)))
}

func get(id uint64) *Record {
	v := streams.Get(seqid.ID(id).String())
	if v == nil {
		return nil
	}
	return v.(*Record)
}

func mustGet(id uint64) *Record {
	r := get(id)
	if r == nil {
		panic("stream " + strconv.FormatUint(id, 10) + " not found")
	}
	return r
}
