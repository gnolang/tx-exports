package membership

import "testing"

func TestJoinFlow(t *testing.T) {
	cfg := &CommunityConfig{
		Name:            "Builders",
		OpenJoin:        false,
		RequireApproval: true,
		MaxMembers:      2,
	}
	if !CanJoin(cfg, 0) {
		t.Fatal("should allow join")
	}
	m := NewMember("g1a", "Alice", cfg, 1000)
	if m.Status != StatusPending {
		t.Fatal("expected pending")
	}
	Activate(&m, cfg)
	if m.Status != StatusActive || cfg.ActiveCount != 1 {
		t.Fatal("activate failed")
	}
	m2 := NewMember("g1b", "Bob", cfg, 1001)
	Activate(&m2, cfg)
	if CanJoin(cfg, cfg.ActiveCount) {
		t.Fatal("max members reached")
	}
	Leave(&m, cfg)
	if cfg.ActiveCount != 1 {
		t.Fatalf("expected 1 active, got %d", cfg.ActiveCount)
	}
}
