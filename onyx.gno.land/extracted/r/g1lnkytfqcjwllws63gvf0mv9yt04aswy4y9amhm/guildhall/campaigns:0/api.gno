package campaigns

import (
	"chain"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaign/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/jsonw/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	apiMaxLimit = 50
	apiMaxScan  = 2000
)

// renderAPI serves JSON for the web app, under Render("api/..."):
//
//	api/stats                                       counts, escrow totals, council, paused
//	api/campaigns?status=&tag=&page=&limit=         newest first; status "all" or empty for every campaign
//	api/campaign/<id>                               one campaign
//	api/campaign/<id>/claims?status=&page=&limit=   its claims, newest first
//	api/campaign/<id>/claimant/<address>            {"claim": an address's latest claim, or null}
//	api/user/<address>?page=&limit=                 campaigns an address is involved in, with roles and their claim
func renderAPI(route string, q url.Values) string {
	parts := strings.Split(route, "/")
	switch {
	case route == "api/stats":
		return apiStats()
	case route == "api/campaigns":
		status := q.Get("status")
		if _, ok := campaign.ParseStatus(status); status != "" && status != "all" && !ok {
			return apiError("unknown status")
		}
		limit := limitOf(q)
		list, more := scan(status, strings.ToLower(q.Get("tag")), (pageOf(q)-1)*limit, limit)
		items := make([]string, len(list))
		for i, c := range list {
			items[i] = campaignJSON(c, false)
		}
		return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(more))
	case len(parts) >= 3 && len(parts) <= 5 && parts[1] == "campaign":
		id, err := strconv.ParseUint(parts[2], 10, 64)
		if err != nil {
			return apiError("invalid id")
		}
		c := getCampaign(id)
		if c == nil {
			return apiError("not found")
		}
		if len(parts) == 3 {
			return campaignJSON(c, true)
		}
		if len(parts) == 4 && parts[3] == "claims" {
			return apiClaims(c, q)
		}
		if len(parts) == 5 && parts[3] == "claimant" {
			addr := address(parts[4])
			if !addr.IsValid() {
				return apiError("invalid address")
			}
			mine := jsonw.Null
			if cl := c.ClaimOf(addr); cl != nil {
				mine = claimJSON(cl)
			}
			return jsonw.Obj("claim", mine)
		}
		return apiError("unknown endpoint")
	case len(parts) == 3 && parts[1] == "user":
		return apiUser(address(parts[2]), q)
	}
	return apiError("unknown endpoint")
}

func apiStats() string {
	var escrow []string
	escrowed.Iterate("", "", func(k string, v any) bool {
		if amt := v.(int64); amt > 0 {
			escrow = append(escrow, jsonw.Obj(append([]string{"amount", jsonw.Int(amt)}, denomFields(k, grc20reg.Get(k) != nil)...)...))
		}
		return false
	})
	return jsonw.Obj(
		"total", jsonw.Int(int64(campaigns.Size())),
		"open", jsonw.Int(int64(statusCount[campaign.StatusOpen])),
		"closed", jsonw.Int(int64(statusCount[campaign.StatusClosed])),
		"escrow", jsonw.Arr(escrow),
		"council", jsonw.String(council.Owner().String()),
		"paused", jsonw.Bool(paused),
		"realmAddress", jsonw.String(chain.PackageAddress(realmPath).String()),
		"claimShareBps", jsonw.Int(ClaimShareBps),
		"maxSlots", jsonw.Int(campaign.MaxSlots),
	)
}

func apiClaims(c *campaign.Campaign, q url.Values) string {
	var st *campaign.ClaimStatus
	if s := q.Get("status"); s != "" && s != "all" {
		parsed, ok := campaign.ParseClaimStatus(s)
		if !ok {
			return apiError("unknown status")
		}
		st = &parsed
	}
	limit := limitOf(q)
	list, more := c.Claims(st, (pageOf(q)-1)*limit, limit)
	items := make([]string, len(list))
	for i, cl := range list {
		items[i] = claimJSON(cl)
	}
	return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(more))
}

func apiUser(addr address, q url.Values) string {
	if !addr.IsValid() {
		return apiError("invalid address")
	}
	limit := limitOf(q)
	var items []string
	more := false
	if v := byUser.Get(addr.String()); v != nil {
		ids := v.(*avl.Tree)
		ids.ReverseIterateByOffset((pageOf(q)-1)*limit, limit, func(k string, _ any) bool {
			if cv := campaigns.Get(k); cv != nil {
				c := cv.(*campaign.Campaign)
				mine := jsonw.Null
				if cl := c.ClaimOf(addr); cl != nil {
					mine = claimJSON(cl)
				}
				items = append(items, jsonw.Obj("campaign", campaignJSON(c, false), "roles", jsonw.Strings(roles(c, addr)), "claim", mine))
			}
			return false
		})
		more = ids.Size() > pageOf(q)*limit
	}
	return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(more))
}

func campaignJSON(c *campaign.Campaign, full bool) string {
	fields := []string{
		"id", jsonw.Uint(c.ID),
		"title", jsonw.String(c.Title),
		"tags", jsonw.Strings(c.Tags),
		"status", jsonw.String(c.Status.String()),
		"poster", jsonw.String(c.Poster.String()),
		"reward", jsonw.Int(c.Reward),
		"slots", jsonw.Int(int64(c.Slots)),
		"paid", jsonw.Int(int64(c.Paid)),
		"pending", jsonw.Int(int64(c.Pending)),
		"rejected", jsonw.Int(int64(c.Rejected)),
		"refunded", jsonw.Int(int64(c.Refunded)),
		"freeSlots", jsonw.Int(int64(c.FreeSlots())),
		"claims", jsonw.Int(int64(c.ClaimCount())),
		"total", jsonw.Int(c.Total()),
		"escrowed", jsonw.Int(c.Escrowed()),
		"paidOut", jsonw.Int(c.PaidOut()),
		"deadline", jsonw.Time(c.Deadline),
		"createdAt", jsonw.Time(c.CreatedAt),
	}
	fields = append(fields, denomFields(c.Denom, c.IsGRC20)...)
	if full {
		fields = append(fields,
			"description", jsonw.String(c.Description),
			"link", jsonw.String(c.Link),
			"reviewers", jsonw.Addresses(c.Reviewers),
			"closedAt", jsonw.Time(c.ClosedAt),
			"claimShareBps", jsonw.Int(ClaimShareBps),
		)
	}
	return jsonw.Obj(fields...)
}

func claimJSON(cl *campaign.Claim) string {
	reviewer := ""
	if cl.ReviewedBy != "" {
		reviewer = cl.ReviewedBy.String()
	}
	return jsonw.Obj(
		"number", jsonw.Int(int64(cl.Number)),
		"claimant", jsonw.String(cl.Claimant.String()),
		"proof", jsonw.String(cl.Proof),
		"status", jsonw.String(cl.Status.String()),
		"at", jsonw.Time(cl.At),
		"reviewedBy", jsonw.String(reviewer),
		"reviewedAt", jsonw.Time(cl.ReviewedAt),
		"reason", jsonw.String(cl.Reason),
	)
}

// denomFields describes how to display amounts of denom.
func denomFields(denom string, isGRC20 bool) []string {
	symbol, decimals := symbolOf(denom, isGRC20)
	return []string{
		"denom", jsonw.String(denom),
		"isGRC20", jsonw.Bool(isGRC20),
		"symbol", jsonw.String(symbol),
		"decimals", jsonw.Int(int64(decimals)),
	}
}

func limitOf(q url.Values) int {
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
