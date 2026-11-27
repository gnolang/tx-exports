package gasscope_reg

import (
	"strings"
	"testing"
)

const testOwner = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"

func TestSubmitAndVerify(t *testing.T) {
	before := GetProfileCount()
	id := submit(testOwner, "gno.land/r/gnoland/blog", 140, 2, "LOOP_STRING_CONCAT", "{}")
	if GetProfileCount() != before+1 || GetReportJSON(id) != "{}" || profiles[id].Owner != testOwner {
		t.Fatal("profile or caller was not stored")
	}
	verify(testOwner, id)
	if !strings.Contains(ListProfiles(0), "\"verified\":true") || Render("profiles/0") != ListProfiles(0) || !strings.Contains(Render(""), "data:image/svg+xml;base64,PHN2Zy") {
		t.Fatal("profile attestation, listing, or chart missing")
	}
}

func TestRegistryCrossing(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(address(testOwner)))
	id := SubmitProfile(cross(cur), "gno.land/r/gnoland/blog", 20, 0, "", "{}")
	if profiles[id].Owner != testOwner {
		t.Fatalf("unexpected caller: %q", profiles[id].Owner)
	}
	VerifyProfile(cross(cur), id)
	if !profiles[id].Verified {
		t.Fatal("missing attestation")
	}
}

func TestLeaderboardPages(t *testing.T) {
	for score := 0; score <= pageSize; score++ {
		submit(testOwner, "gno.land/r/gnoland/blog", score+1000, 0, "", "{}")
	}
	tie := submit(testOwner, "gno.land/r/gnoland/blog", 1000+pageSize, 0, "", "{}")
	first := page(0)
	second := page(pageSize)
	if len(first) != pageSize || first[0].ID != tie || first[1].TotalGas != first[0].TotalGas ||
		len(second) < 2 || second[0].TotalGas != 1001 || second[1].TotalGas != 1000 {
		t.Fatal("profiles were not ordered across pages")
	}
}
