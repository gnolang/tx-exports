package nightsky

import (
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const (
	owner = "g1owner"
	guest = "g1guest"
)

func newTestRealm() *TelescopeRealm {
	cfg := NewTelescopeConfig("Test Scope", "Seestar S50", 49.0, 1.0, owner, "/r/test/telescope")
	return NewTelescopeRealm(&cfg)
}

func TestNewTelescopeConfig(t *testing.T) {
	cfg := NewTelescopeConfig("Scope", "Model", 1.5, 2.5, owner, "/r/x/y")
	uassert.Equal(t, "Scope", cfg.Name)
	uassert.Equal(t, "offline", cfg.Status) // starts offline
	uassert.Equal(t, owner, cfg.Owner)

	cfg.UpdateStatus("online")
	uassert.Equal(t, "online", cfg.Status)
}

func TestValidateCommand(cur realm, t *testing.T) {
	cfg := NewTelescopeConfig("Scope", "Model", 0, 0, owner, "/r/x/y")

	// Valid capture and stop should not panic.
	uassert.NotPanics(t, cur, func() {
		ValidateCommand(TelescopeCommand{CommandType: "capture", TargetRA: 5.5, TargetDec: 22.5, Exposure: 60}, cfg)
	})
	uassert.NotPanics(t, cur, func() {
		// stop ignores coordinates entirely.
		ValidateCommand(TelescopeCommand{CommandType: "stop", TargetRA: 999, TargetDec: 999, Exposure: 0}, cfg)
	})

	cases := []struct {
		name string
		cmd  TelescopeCommand
		msg  string
	}{
		{"bad type", TelescopeCommand{CommandType: "explode"}, "invalid command type"},
		{"RA low", TelescopeCommand{CommandType: "capture", TargetRA: -1, Exposure: 10}, "invalid RA"},
		{"RA high", TelescopeCommand{CommandType: "capture", TargetRA: 24, Exposure: 10}, "invalid RA"},
		{"Dec low", TelescopeCommand{CommandType: "capture", TargetRA: 1, TargetDec: -91, Exposure: 10}, "invalid Dec"},
		{"Dec high", TelescopeCommand{CommandType: "capture", TargetRA: 1, TargetDec: 91, Exposure: 10}, "invalid Dec"},
		{"exp low", TelescopeCommand{CommandType: "capture", TargetRA: 1, Exposure: 0}, "invalid exposure"},
		{"exp high", TelescopeCommand{CommandType: "capture", TargetRA: 1, Exposure: 301}, "invalid exposure"},
	}
	for _, tc := range cases {
		cmd := tc.cmd
		uassert.PanicsContains(t, cur, tc.msg, func() { ValidateCommand(cmd, cfg) }, tc.name)
	}
}

func TestIsAccessAllowed(t *testing.T) {
	rules := avl.NewTree()

	// Unknown address: denied.
	uassert.False(t, IsAccessAllowed(guest, rules))

	// Never-expires rule (zero time): allowed.
	rules.Set(guest, AccessRule{AllowedAddress: guest, ExpiresAt: time.Time{}})
	uassert.True(t, IsAccessAllowed(guest, rules))

	// Future expiry: allowed.
	rules.Set(guest, AccessRule{AllowedAddress: guest, ExpiresAt: time.Now().Add(time.Hour)})
	uassert.True(t, IsAccessAllowed(guest, rules))

	// Past expiry: denied.
	rules.Set(guest, AccessRule{AllowedAddress: guest, ExpiresAt: time.Now().Add(-time.Hour)})
	uassert.False(t, IsAccessAllowed(guest, rules))
}

func TestAccessFlow(cur realm, t *testing.T) {
	r := newTestRealm()

	// Owner can always submit.
	urequire.NotPanics(t, cur, func() {
		r.SubmitCommand(owner, "capture", 5, 10, 30)
	})

	// Guest without a grant is denied.
	uassert.PanicsContains(t, cur, "access denied", func() {
		r.SubmitCommand(guest, "capture", 5, 10, 30)
	})

	// Grant, then guest can submit.
	r.GrantAccess(owner, guest, 0) // 0 = never expires
	uassert.Equal(t, 1, r.GetAccessRuleCount())
	urequire.NotPanics(t, cur, func() {
		r.SubmitCommand(guest, "capture", 5, 10, 30)
	})

	// Re-granting the same address does not duplicate the rule.
	r.GrantAccess(owner, guest, 5)
	uassert.Equal(t, 1, r.GetAccessRuleCount())

	// Revoke, then guest is denied again.
	r.RevokeAccess(owner, guest)
	uassert.Equal(t, 0, r.GetAccessRuleCount())
	uassert.PanicsContains(t, cur, "access denied", func() {
		r.SubmitCommand(guest, "capture", 5, 10, 30)
	})

	// Non-owner cannot grant access.
	uassert.PanicsContains(t, cur, "owner only", func() {
		r.GrantAccess(guest, "g1evil", 0)
	})
}

func TestCommandQueueFIFO(cur realm, t *testing.T) {
	r := newTestRealm()

	r.SubmitCommand(owner, "capture", 1, 1, 10)
	r.SubmitCommand(owner, "capture", 2, 2, 20)
	r.SubmitCommand(owner, "stop", 0, 0, 0)
	uassert.Equal(t, 3, r.GetCommandCount())

	// FIFO order.
	c1 := r.GetNextCommand(owner)
	uassert.Equal(t, "capture", c1.CommandType)
	uassert.Equal(t, int64(10), int64(c1.Exposure))

	c2 := r.GetNextCommand(owner)
	uassert.Equal(t, int64(20), int64(c2.Exposure))

	c3 := r.GetNextCommand(owner)
	uassert.Equal(t, "stop", c3.CommandType)

	uassert.Equal(t, 0, r.GetCommandCount())

	// Draining an empty queue panics.
	uassert.PanicsContains(t, cur, "no commands", func() { r.GetNextCommand(owner) })

	// Only the owner may pull commands.
	r.SubmitCommand(owner, "stop", 0, 0, 0)
	uassert.PanicsContains(t, cur, "owner only", func() { r.GetNextCommand(guest) })

	// Emergency stop clears everything and sets status online.
	r.ClearCommandQueue(owner)
	uassert.Equal(t, 0, r.GetCommandCount())
	uassert.Equal(t, "online", r.Config.Status)
}

func TestRecordCaptureUpdatesStatus(cur realm, t *testing.T) {
	r := newTestRealm()

	// Submitting a command flips status to busy.
	r.SubmitCommand(owner, "capture", 5, 10, 30)
	uassert.Equal(t, "busy", r.Config.Status)

	// Recording a capture flips it back to online and stores the capture.
	r.RecordCapture(owner, "https://img/1.png", 5, 10, 30, owner)
	uassert.Equal(t, "online", r.Config.Status)
	uassert.Equal(t, 1, r.GetCaptureCount())

	// Empty image URL is rejected.
	uassert.PanicsContains(t, cur, "image URL", func() {
		r.RecordCapture(owner, "", 5, 10, 30, owner)
	})

	// Non-owner cannot record.
	uassert.PanicsContains(t, cur, "owner only", func() {
		r.RecordCapture(guest, "https://img/2.png", 5, 10, 30, guest)
	})
}

// --- CaptureFeed tests ------------------------------------------------------

func mkCap(url string) CaptureResult {
	return CaptureResult{ImageURL: url}
}

func TestCaptureFeedOrderAndLatest(t *testing.T) {
	f := NewCaptureFeed(10)
	uassert.Equal(t, 0, f.Len())

	_, ok := f.Latest()
	uassert.False(t, ok)

	f.Add(mkCap("a"))
	f.Add(mkCap("b"))
	f.Add(mkCap("c"))
	uassert.Equal(t, 3, f.Len())

	latest, ok := f.Latest()
	urequire.True(t, ok)
	uassert.Equal(t, "c", latest.ImageURL)

	// Newest-first iteration order.
	var got []string
	f.IterateNewest(func(c CaptureResult) bool {
		got = append(got, c.ImageURL)
		return false
	})
	urequire.Equal(t, 3, len(got))
	uassert.Equal(t, "c", got[0])
	uassert.Equal(t, "b", got[1])
	uassert.Equal(t, "a", got[2])

	// Early stop.
	count := 0
	f.IterateNewest(func(c CaptureResult) bool {
		count++
		return true // stop after first
	})
	uassert.Equal(t, 1, count)
}

func TestCaptureFeedTrim(t *testing.T) {
	f := NewCaptureFeed(3)
	f.Add(mkCap("1"))
	f.Add(mkCap("2"))
	f.Add(mkCap("3"))
	f.Add(mkCap("4")) // evicts "1"
	f.Add(mkCap("5")) // evicts "2"

	uassert.Equal(t, 3, f.Len())

	var got []string
	f.IterateNewest(func(c CaptureResult) bool {
		got = append(got, c.ImageURL)
		return false
	})
	// Newest-first: 5, 4, 3 — oldest two evicted.
	uassert.Equal(t, "5", got[0])
	uassert.Equal(t, "4", got[1])
	uassert.Equal(t, "3", got[2])
}

func TestCaptureFeedRemoveAt(t *testing.T) {
	f := NewCaptureFeed(10)
	f.Add(mkCap("a"))
	f.Add(mkCap("b"))
	f.Add(mkCap("c")) // newest-first: c(0), b(1), a(2)

	// Out-of-range is a no-op returning false.
	uassert.False(t, f.RemoveAt(-1))
	uassert.False(t, f.RemoveAt(3))
	uassert.Equal(t, 3, f.Len())

	// Remove the middle (b).
	uassert.True(t, f.RemoveAt(1))
	uassert.Equal(t, 2, f.Len())

	var got []string
	f.IterateNewest(func(c CaptureResult) bool {
		got = append(got, c.ImageURL)
		return false
	})
	uassert.Equal(t, "c", got[0])
	uassert.Equal(t, "a", got[1])

	// Removing newest (c).
	uassert.True(t, f.RemoveAt(0))
	latest, ok := f.Latest()
	urequire.True(t, ok)
	uassert.Equal(t, "a", latest.ImageURL)
}

func TestNewCaptureFeedRejectsNonPositive(cur realm, t *testing.T) {
	uassert.PanicsContains(t, cur, "must be positive", func() { NewCaptureFeed(0) })
}
