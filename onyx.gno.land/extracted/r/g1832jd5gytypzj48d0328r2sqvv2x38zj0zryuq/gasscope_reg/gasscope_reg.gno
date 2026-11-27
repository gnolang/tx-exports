package gasscope_reg

import (
	"encoding/base64"
	"strconv"
	"strings"
)

type Profile struct {
	ID            int    `json:"id"`
	RealmPath     string `json:"realmPath"`
	TotalGas      int    `json:"totalGas"`
	HotspotsCount int    `json:"hotspotsCount"`
	TopRule       string `json:"topRule"`
	Owner         string `json:"owner"`
	Verified      bool   `json:"verified"`
}

const (
	pageSize = 20
	maxScore = 1000000000
	scoreBit = 1 << 29
)

var count int
var profiles = make(map[int]Profile)
var reports = make(map[int]string)
var ranking scoreNode

// Each branch spans a score prefix. Subtree sizes let a query skip earlier pages.
type scoreNode struct {
	size      int
	low, high *scoreNode
	ids       []int
}

func (n *scoreNode) add(score, id, bit int) {
	n.size++
	if bit == 0 {
		n.ids = append(n.ids, id)
		return
	}
	if score&bit != 0 {
		if n.high == nil {
			n.high = &scoreNode{}
		}
		n.high.add(score, id, bit>>1)
		return
	}
	if n.low == nil {
		n.low = &scoreNode{}
	}
	n.low.add(score, id, bit>>1)
}

func (n *scoreNode) collect(offset *int, results *[]Profile) {
	if n == nil || len(*results) == pageSize {
		return
	}
	if *offset >= n.size {
		*offset -= n.size
		return
	}
	if len(n.ids) != 0 {
		for i := len(n.ids) - 1 - *offset; i >= 0 && len(*results) < pageSize; i-- {
			*results = append(*results, profiles[n.ids[i]])
		}
		*offset = 0
		return
	}
	n.high.collect(offset, results)
	n.low.collect(offset, results)
}

func validPath(p string) bool {
	parts := strings.Split(p, "/")
	if len(parts) < 4 || parts[0] != "gno.land" || parts[1] != "r" {
		return false
	}
	for _, part := range parts[2:] {
		if len(part) == 0 {
			return false
		}
		for _, c := range part {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_') {
				return false
			}
		}
	}
	return true
}

func validRule(rule string) bool {
	switch rule {
	case "", "LOOP_STRING_CONCAT", "HOT_UFMT_SPRINTF", "UNBOUNDED_AVL_ITER", "UNBOUNDED_SLICE_APPEND", "CROSS_REALM_IN_LOOP", "LARGE_STATE_SERIALIZE":
		return true
	}
	return false
}

func SubmitProfile(cur realm, realmPath string, totalGas int, hotspotsCount int, topRule string, reportJSON string) int {
	return submit(string(cur.Previous().Address()), realmPath, totalGas, hotspotsCount, topRule, reportJSON)
}

func submit(owner string, realmPath string, totalGas int, hotspotsCount int, topRule string, reportJSON string) int {
	if len(realmPath) > 160 || !validPath(realmPath) || totalGas < 0 || totalGas > maxScore || hotspotsCount < 0 || !validRule(topRule) || (hotspotsCount == 0) != (topRule == "") {
		panic("invalid GasScope profile summary")
	}
	if len(reportJSON) == 0 || len(reportJSON) > 32768 {
		panic("profile report must be between 1 byte and 32 KiB")
	}

	count++
	profiles[count] = Profile{
		ID: count, RealmPath: realmPath, TotalGas: totalGas, HotspotsCount: hotspotsCount,
		TopRule: topRule, Owner: owner,
	}
	reports[count] = reportJSON
	ranking.add(totalGas, count, scoreBit)
	return count
}

// VerifyProfile records the submitter's attestation.
func VerifyProfile(cur realm, id int) {
	verify(string(cur.Previous().Address()), id)
}

func verify(owner string, id int) {
	item, ok := profiles[id]
	if !ok {
		panic("unknown GasScope profile")
	}
	if item.Owner != owner {
		panic("only the submitter can attest this profile")
	}
	item.Verified = true
	profiles[id] = item
}

func GetProfileCount() int { return count }

func GetReportJSON(id int) string { return reports[id] }

func page(offset int) []Profile {
	results := make([]Profile, 0, pageSize)
	if offset >= 0 {
		ranking.collect(&offset, &results)
	}
	return results
}

func ListProfiles(offset int) string {
	var b strings.Builder
	b.WriteByte('[')
	for i, p := range page(offset) {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("{\"id\":" + strconv.Itoa(p.ID) + ",\"realmPath\":" + strconv.Quote(p.RealmPath) + ",\"totalGas\":" + strconv.Itoa(p.TotalGas) + ",\"hotspotsCount\":" + strconv.Itoa(p.HotspotsCount) + ",\"topRule\":" + strconv.Quote(p.TopRule) + ",\"owner\":" + strconv.Quote(p.Owner) + ",\"verified\":" + strconv.FormatBool(p.Verified) + "}")
	}
	b.WriteByte(']')
	return b.String()
}

func Render(path string) string {
	if strings.HasPrefix(path, "profiles/") {
		offset, err := strconv.Atoi(strings.TrimPrefix(path, "profiles/"))
		if err != nil {
			return "[]"
		}
		return ListProfiles(offset)
	}
	offset, _ := strconv.Atoi(path)
	results := page(offset)
	var b strings.Builder
	b.WriteString("# GasScope leaderboard\n\nRanked by estimated gas points. Attestations are recorded by submitters.\n\n")
	b.WriteString("| ID | Realm | Gas points | Hotspots | Top rule | Attested |\n| --: | --- | --: | --: | --- | --- |\n")
	for _, p := range results {
		b.WriteString("| " + strconv.Itoa(p.ID) + " | `" + p.RealmPath + "` | " + strconv.Itoa(p.TotalGas) + " | " + strconv.Itoa(p.HotspotsCount) + " | " + p.TopRule + " | " + strconv.FormatBool(p.Verified) + " |\n")
	}
	if len(results) == 0 {
		return b.String() + "\nNo submissions on this page.\n"
	}
	var chart strings.Builder
	chart.WriteString("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 " + strconv.Itoa(len(results)*22) + "\" font-family=\"monospace\" font-size=\"11\">")
	for i, p := range results {
		width := (int64(p.TotalGas) * 240) / (int64(results[0].TotalGas) + 1)
		y := i * 22
		chart.WriteString("<text x=\"2\" y=\"" + strconv.Itoa(y+14) + "\" fill=\"#64748B\">#" + strconv.Itoa(p.ID) + "</text><rect fill=\"#38BDF8\" x=\"78\" y=\"" + strconv.Itoa(y) + "\" width=\"" + strconv.FormatInt(width, 10) + "\" height=\"15\"/>")
	}
	chart.WriteString("</svg>")
	b.WriteString("\n![Estimated gas distribution](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(chart.String())) + ")\n")
	return b.String()
}
