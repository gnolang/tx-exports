package idox

import (
	"strings"
	"testing"
)

func TestRenderHelpersAndRoutes(t *testing.T) {
	if got := formatGNOT(30_000_000); got != "30.00 GNOT" {
		t.Fatalf("expected 30.00 GNOT, got %s", got)
	}
	if got := formatGNOT(1_050_000); got != "1.05 GNOT" {
		t.Fatalf("expected 1.05 GNOT, got %s", got)
	}
	if got := progressBar(30_000_000, 70_000_000, 10); !strings.Contains(got, "42%") {
		t.Fatalf("expected 42%% progress bar, got %s", got)
	}
	if got := formatProof("ipfs://QmFramingInspectionPassedHash123"); !strings.Contains(got, "https://ipfs.io/ipfs/QmFramingInspectionPassedHash123") {
		t.Fatalf("expected clickable IPFS gateway URL, got %s", got)
	}
	if got := Render("vault/9999"); !strings.Contains(got, "Vault #9999 Not Found") {
		t.Fatalf("expected clean not-found page for missing vault, got %s", got)
	}
	if got := Render("audits"); !strings.Contains(got, "Idox AI Audit & Guardrail Log") {
		t.Fatalf("expected audit log heading, got %s", got)
	}
}
