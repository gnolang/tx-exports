package whitelist

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/ratelimit"
)

// Entry records when an address was whitelisted and by whom.
type Entry struct {
	Addr       address
	AddedBy    address
	AddedAt    int64
}

var (
	admin        address
	entries      *avl.Tree // addr -> *Entry
	selfRequests *avl.Tree // addr -> *ratelimit.TokenBucket, throttles self-service requests
	openEnrollment bool
)

func init() {
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")
	entries = avl.NewTree()
	selfRequests = avl.NewTree()
	openEnrollment = false
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("whitelist: must be a direct user call")
	}
	return cur.Previous().Address()
}

// AddAddress lets the admin add an address directly.
func AddAddress(cur realm, addr address) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("whitelist: admin only")
	}
	entries.Set(string(addr), &Entry{
		Addr:    addr,
		AddedBy: caller,
		AddedAt: runtime.ChainHeight(),
	})
}

// RemoveAddress lets the admin revoke an address.
func RemoveAddress(cur realm, addr address) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("whitelist: admin only")
	}
	key := string(addr)
	if entries.Has(key) {
		entries.Remove(key)
	}
}

// SetOpenEnrollment toggles whether addresses can self-enroll via RequestJoin.
func SetOpenEnrollment(cur realm, open bool) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("whitelist: admin only")
	}
	openEnrollment = open
}

// RequestJoin lets any address self-enroll when open enrollment is active,
// rate-limited to prevent spam.
func RequestJoin(cur realm) {
	caller := assertUserCall(cur)
	if !openEnrollment {
		panic("whitelist: open enrollment is not active")
	}
	key := string(caller)
	if entries.Has(key) {
		panic("whitelist: already whitelisted")
	}

	now := runtime.ChainHeight()
	var bucket *ratelimit.TokenBucket
	if selfRequests.Has(key) {
		bucket = selfRequests.Get(key).(*ratelimit.TokenBucket)
	} else {
		bucket = ratelimit.NewTokenBucket(3, 1, now)
		selfRequests.Set(key, bucket)
	}
	if !bucket.Allow(now, 1) {
		panic("whitelist: rate limit exceeded, try again later")
	}

	entries.Set(key, &Entry{
		Addr:    caller,
		AddedBy: caller,
		AddedAt: now,
	})
}

// IsWhitelisted reports whether an address is currently on the list.
func IsWhitelisted(addr address) bool {
	return entries.Has(string(addr))
}

func Render(path string) string {
	out := "# Whitelist\n\n"
	status := "closed"
	if openEnrollment {
		status = "open"
	}
	out += ufmt.Sprintf("Enrollment: %s | Total entries: %d\n\n", status, entries.Size())
	entries.Iterate("", "", func(key string, value interface{}) bool {
		e := value.(*Entry)
		out += ufmt.Sprintf("- %s (added by %s at height %d)\n", e.Addr, e.AddedBy, e.AddedAt)
		return false
	})
	return out
}
