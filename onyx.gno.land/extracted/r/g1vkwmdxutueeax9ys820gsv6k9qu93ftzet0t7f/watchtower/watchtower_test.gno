package watchtower

import (
	"testing"
)

// Realm tests follow the v1.8 style: crossing functions are exercised by
// forwarding the test's own realm value with cross(cur); the caller seen
// by the realm is cur.Previous().Address(), consistent within a test.

func TestRegisterAndHeartbeat(cur realm, t *testing.T) {
	services = nil
	order = nil

	RegisterService(cross(cur), "demo", "gno.land/r/demo", 300)
	if got := GetStatus("demo"); got != "unknown" {
		t.Fatalf("fresh service should be unknown, got %s", got)
	}
	Heartbeat(cross(cur), "demo")
	if got := GetStatus("demo"); got != "operational" {
		t.Fatalf("after heartbeat should be operational, got %s", got)
	}
}

func TestIncidentLifecycle(cur realm, t *testing.T) {
	services = nil
	order = nil

	RegisterService(cross(cur), "demo", "gno.land/r/demo", 300)
	ReportIncident(cross(cur), "demo", "RPC slow", "p95 latency spiking")
	s := services["demo"]
	if len(s.Incidents) != 1 || s.Incidents[0].ClosedAt != 0 {
		t.Fatalf("expected 1 open incident")
	}
	ResolveIncident(cross(cur), "demo", s.Incidents[0].ID)
	if s.Incidents[0].ClosedAt == 0 {
		t.Fatalf("incident should be closed")
	}
}

func TestRenderBoard(cur realm, t *testing.T) {
	services = nil
	order = nil

	out := Render("")
	if out == "" {
		t.Fatalf("empty board should still render")
	}
	RegisterService(cross(cur), "demo", "gno.land/r/demo", 300)
	if got := Render("/demo"); got == "" {
		t.Fatalf("service page should render")
	}
}
