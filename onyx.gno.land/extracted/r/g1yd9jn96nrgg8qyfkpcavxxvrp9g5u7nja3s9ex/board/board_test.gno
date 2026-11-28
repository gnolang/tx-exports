package board

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	hashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	pkg   = "gno.land/r/demo/slowboard"
)

var alice = testutils.TestAddress("alice")

func TestSubmitAndHistory(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))

	id := Submit(cross(cur), pkg, hashA, "assayer/0.1", "40,30,35,70,50",
		"Post|O(n)|200|1500000|7000|1600;Render:|O(n)|200|900000|4300|0",
		"AS-G02|medium|board.gno|21;AS-S01|critical|vault.gno|30")
	uassert.Equal(t, 1, id)

	r := GetReport(id)
	uassert.Equal(t, 1, r.Version)
	uassert.Equal(t, 2, len(r.Funcs))
	uassert.Equal(t, "O(n)", r.Funcs[0].Class)
	uassert.Equal(t, int64(1500000), r.Funcs[0].GasAtMaxN)
	uassert.Equal(t, 21, r.Findings[0].Line)

	id2 := Submit(cross(cur), pkg, hashB, "assayer/0.1", "90,95,90,85,80",
		"Post|O(log n)|200|300000|20|180;Render:|O(1)|200|200000|0|0", "")
	uassert.Equal(t, 2, Latest(pkg).Version)
	uassert.Equal(t, id2, Latest(pkg).ID)

	score, ok := LatestScore(pkg)
	uassert.True(t, ok)
	uassert.Equal(t, 90, score)
	uassert.Equal(t, 1, PackageCount())

	page := Render("pkg/" + pkg)
	uassert.True(t, strings.Contains(page, "▼ -80%"), page)
	uassert.True(t, strings.Contains(Render(""), "slowboard"))
	uassert.True(t, strings.Contains(Render("badge/"+pkg), "Assayer 90/100"))
}

func TestSubmitRejectsBadInput(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))

	uassert.AbortsContains(t, cur, "sourceHash", func() {
		Submit(cross(cur), pkg, "xyz", "", "1,2,3,4,5", "", "")
	})
	uassert.AbortsContains(t, cur, "bad score", func() {
		Submit(cross(cur), pkg, hashA, "", "1,2,3,4,500", "", "")
	})
	uassert.AbortsContains(t, cur, "complexity", func() {
		Submit(cross(cur), pkg, hashA, "", "1,2,3,4,5", "Post|O(2^n)|1|1|1|1", "")
	})
	uassert.AbortsContains(t, cur, "invalid pkgPath", func() {
		Submit(cross(cur), "evil.com/x", hashA, "", "1,2,3,4,5", "", "")
	})
}

func TestNoDuplicateSubmission(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("bob")))
	h := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	Submit(cross(cur), "gno.land/r/demo/x", h, "", "1,2,3,4,5", "", "")
	uassert.AbortsContains(t, cur, "already submitted", func() {
		Submit(cross(cur), "gno.land/r/demo/x", h, "", "1,2,3,4,5", "", "")
	})
}

func TestJSONAPI(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("carol")))
	h := "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	id := Submit(cross(cur), "gno.land/r/demo/json", h, "assayer/0.1", "70,80,60,75,90",
		`Add"Post|O(n)|10|100|5|50`, "AS-T01|high|a.gno|3;AS-S06|medium|a.gno|9")

	full := Render("api/report/" + strconv.Itoa(id))
	uassert.True(t, strings.Contains(full, `"pkgpath":"gno.land/r/demo/json"`), full)
	uassert.True(t, strings.Contains(full, `"name":"Add\"Post"`), "quotes must be escaped: "+full)
	uassert.True(t, strings.Contains(full, `"counts":{"high":1,"medium":1}`), full)
	uassert.True(t, strings.Contains(full, `{"rule":"AS-T01","severity":"high","file":"a.gno","line":3}`), full)

	list := Render("api/reports?page=1&size=2")
	uassert.True(t, strings.HasPrefix(list, `{"total":`), list)
	uassert.True(t, strings.Contains(list, `"limit":2`), list)
	uassert.False(t, strings.Contains(list, `"findings"`), "list items are summaries")

	uassert.True(t, strings.Contains(Render("api/pkg/gno.land/r/demo/json"), `"version":1`))
	uassert.True(t, strings.Contains(Render("api/stats"), `"reports":`))
	uassert.Equal(t, `{"error":"not found"}`, Render("api/report/9999"))
}
