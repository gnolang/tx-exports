package fund

import "gno.land/p/nt/ufmt/v0"

// listCodes are the public sanctions lists the screening agent uses.
var listCodes = []struct{ Code, Name string }{
	{"UN", "UN Security Council Consolidated List"},
	{"AE-LTL", "UAE Local Terrorist List"},
	{"US-SDN", "OFAC Specially Designated Nationals List"},
	{"US-CONS", "OFAC Consolidated (non-SDN) List"},
	{"EU-FSF", "EU Financial Sanctions Files (consolidated list)"},
	{"UK-SL", "UK Sanctions List"},
}

func listName(code string) string {
	for _, l := range listCodes {
		if l.Code == code {
			return l.Name
		}
	}
	return ""
}

// PostListSnapshot records a sanctions-list file the agent screens against:
// its list code, the publication date (YYYY-MM-DD) and the SHA-256 of the
// official file. Agent session only. It carries no investor data.
func PostListSnapshot(cur realm, list, published, sha string) {
	assertAgent(cur)
	if listName(list) == "" {
		panic("unknown list code")
	}
	checkDate(published)
	checkCommitment(sha)
	if v := lists.Get(list); v != nil && v.(*listSnapshot).sha == sha {
		panic("snapshot already recorded")
	}
	s := &listSnapshot{list: list, published: published, sha: sha, height: heightNow()}
	lists.Set(list, s)
	listSeq++
	listLog.Set(pad(listSeq), s)
	addTrail("screening agent", ufmt.Sprintf("List snapshot %s of %s: %s.", list, published, sha))
}

func checkDate(d string) {
	if len(d) != 10 || d[4] != '-' || d[7] != '-' {
		panic("date must be YYYY-MM-DD")
	}
	for i, r := range d {
		if i == 4 || i == 7 {
			continue
		}
		if r < '0' || r > '9' {
			panic("date must be YYYY-MM-DD")
		}
	}
	if d[5:7] < "01" || d[5:7] > "12" || d[8:10] < "01" || d[8:10] > "31" {
		panic("date must be YYYY-MM-DD")
	}
}
