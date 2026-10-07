package reputation

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/jsonw/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/trust/v0"
	"gno.land/p/nt/avl/v0"
)

const apiMaxLimit = 50

// renderAPI serves JSON for the web app, under Render("api/..."):
//
//	api/stats                                   totals, parameters, admin
//	api/top?limit=                              leaderboard
//	api/profile/<address>                       one contributor
//	api/records?addr=&kind=work|reviews&page=&limit=   newest first; all records without addr
//	api/record/<id>                             one record
//	api/seeds                                   seed reviewers
func renderAPI(route string, q url.Values) string {
	parts := strings.Split(route, "/")
	switch {
	case route == "api/stats":
		return jsonw.Obj(
			"records", jsonw.Int(int64(records.Size())),
			"contributors", jsonw.Int(int64(leaderboard.Size())),
			"seeds", jsonw.Int(int64(seeds.Size())),
			"admin", jsonw.String(Admin().String()),
			"params", jsonw.Obj(
				"base", jsonw.Int(params.Base),
				"trustThreshold", jsonw.Int(params.TrustThreshold),
				"trustFloorBps", jsonw.Int(params.TrustFloorBps),
				"selfFundedFactorBps", jsonw.Int(params.SelfFundedFactorBps),
			),
			"writers", jsonw.Strings(keys(&writers)),
		)
	case route == "api/top":
		var items []string
		for i, s := range Top(apiLimit(q)) {
			items = append(items, jsonw.Obj(
				"rank", jsonw.Int(int64(i+1)),
				"address", jsonw.String(s.Addr.String()),
				"score", jsonw.Int(s.Score),
				"level", jsonw.String(trust.Level(s.Score)),
				"completed", jsonw.Int(int64(CompletedCount(s.Addr))),
				"reviews", jsonw.Int(int64(ReviewCount(s.Addr))),
				"seed", jsonw.Bool(IsSeed(s.Addr)),
			))
		}
		return jsonw.Obj("items", jsonw.Arr(items))
	case len(parts) == 3 && parts[1] == "profile":
		return apiProfile(address(parts[2]))
	case route == "api/records":
		return apiRecords(q)
	case len(parts) == 3 && parts[1] == "record":
		id, err := strconv.ParseUint(parts[2], 10, 64)
		if err != nil {
			return apiError("invalid id")
		}
		r := getRecord(id)
		if r == nil {
			return apiError("not found")
		}
		return recordJSON(r)
	case route == "api/seeds":
		return jsonw.Obj("items", jsonw.Strings(keys(&seeds)))
	}
	return apiError("unknown endpoint")
}

func apiProfile(addr address) string {
	if !addr.IsValid() {
		return apiError("invalid address")
	}
	p := getProfile(addr)
	var earned []string
	score, first, last := int64(0), jsonw.Null, jsonw.Null
	if p != nil {
		score, first, last = p.Score, jsonw.Time(p.First), jsonw.Time(p.Last)
		if p.earned != nil {
			p.earned.Iterate("", "", func(k string, v any) bool {
				earned = append(earned, jsonw.Obj("denom", jsonw.String(k), "amount", jsonw.Int(v.(int64))))
				return false
			})
		}
	}
	return jsonw.Obj(
		"address", jsonw.String(addr.String()),
		"score", jsonw.Int(score),
		"level", jsonw.String(trust.Level(score)),
		"rank", jsonw.Int(int64(Rank(addr))),
		"seed", jsonw.Bool(IsSeed(addr)),
		"completed", jsonw.Int(int64(CompletedCount(addr))),
		"reviews", jsonw.Int(int64(ReviewCount(addr))),
		"earned", jsonw.Arr(earned),
		"firstAt", first,
		"lastAt", last,
	)
}

func apiRecords(q url.Values) string {
	limit := apiLimit(q)
	page := 1
	if n, err := strconv.Atoi(q.Get("page")); err == nil && n > 0 {
		page = n
	}
	offset := (page - 1) * limit

	var rs []Record
	total := 0
	if a := q.Get("addr"); a != "" {
		addr := address(a)
		if !addr.IsValid() {
			return apiError("invalid address")
		}
		if q.Get("kind") == "reviews" {
			rs = ReviewsOf(addr, offset, limit)
			total = ReviewCount(addr)
		} else {
			rs = RecordsOf(addr, offset, limit)
			total = CompletedCount(addr)
		}
	} else {
		rs = latest(offset, limit)
		total = records.Size()
	}
	items := make([]string, len(rs))
	for i := range rs {
		items[i] = recordJSON(&rs[i])
	}
	return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(total > page*limit), "total", jsonw.Int(int64(total)))
}

func recordJSON(r *Record) string {
	return jsonw.Obj(
		"id", jsonw.Uint(r.ID),
		"worker", jsonw.String(r.Worker.String()),
		"poster", jsonw.String(r.Poster.String()),
		"reviewers", jsonw.Addresses(r.Reviewers),
		"reviewerTrustBps", int64s(r.ReviewerTrust),
		"points", jsonw.Int(r.Points),
		"shareBps", jsonw.Int(r.ShareBps),
		"amount", jsonw.Int(r.Amount),
		"denom", jsonw.String(r.Denom),
		"title", jsonw.String(r.Title),
		"link", jsonw.String(r.Link),
		"ref", jsonw.String(r.Ref),
		"source", jsonw.String(r.Source),
		"signedBy", jsonw.String(r.SignedBy.String()),
		"arbitrated", jsonw.Bool(r.Arbitrated),
		"height", jsonw.Int(r.Height),
		"at", jsonw.Time(r.At),
		"voided", jsonw.Bool(r.Voided),
		"voidReason", jsonw.String(r.VoidReason),
	)
}

func int64s(ns []int64) string {
	out := make([]string, len(ns))
	for i, n := range ns {
		out[i] = jsonw.Int(n)
	}
	return jsonw.Arr(out)
}

func keys(t *avl.Tree) []string {
	var out []string
	t.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

func apiLimit(q url.Values) int {
	n, err := strconv.Atoi(q.Get("limit"))
	if err != nil || n < 1 {
		return 20
	}
	if n > apiMaxLimit {
		return apiMaxLimit
	}
	return n
}

func apiError(msg string) string {
	return jsonw.Obj("error", jsonw.String(msg))
}
