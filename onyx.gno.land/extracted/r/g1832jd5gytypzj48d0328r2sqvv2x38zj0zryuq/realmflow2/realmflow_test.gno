package realmflow2

import (
	"strings"
	"testing"
)

func TestScenarioLifecycle(t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")))
	before := GetScenarioCount()
	id := RegisterScenario(cross, "First scenario", "gno.land/r/demo/boards", "payload")
	if id != before+1 || GetScenarioCount() != before+1 {
		t.Fatal("scenario was not registered")
	}
	if !strings.Contains(GetScenario(id), "First scenario | gno.land/r/demo/boards | payload | 0") {
		t.Fatal("scenario was not returned")
	}
	if VerifyScenario(cross, id) != 1 || VerifyScenario(cross, id) != 2 {
		t.Fatal("verification count was not incremented")
	}
	if !strings.HasSuffix(GetScenario(id), " | 2") {
		t.Fatal("verification count was not stored")
	}
	if GetScenario(0) != "" {
		t.Fatal("invalid ID should return empty string")
	}
	if !strings.Contains(Render(""), "First scenario") || !strings.Contains(Render(""), "| 2 |") {
		t.Fatal("catalog missing scenario or count")
	}
	if !strings.Contains(Render("scenario/1"), "First scenario") || !strings.Contains(Render("scenario/1"), "?s=payload") {
		t.Fatal("detail missing scenario or link")
	}
}