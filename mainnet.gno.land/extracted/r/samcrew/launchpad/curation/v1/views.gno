package curation

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/samcrew/launchpad/meta/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

// int64 values are decimal strings so a JSON client cannot round them.
func jsonInt(n int64) string { return meta.JSONString(strconv.FormatInt(n, 10)) }

func StateJSON() string {
	return "{" +
		`"admin":` + meta.JSONString(admin.String()) +
		`,"pendingAdmin":` + meta.JSONString(pendingAdmin.String()) +
		`,"activeManagers":` + strconv.Itoa(ActiveManagerCount()) +
		`,"maxSeats":` + strconv.Itoa(maxSeats) + "}"
}

// ManagersJSON lists the active seats, ordered by account.
func ManagersJSON() string {
	var b strings.Builder
	b.WriteByte('[')
	at := now()
	seats.Iterate("", "", func(account string, v any) bool {
		s := v.(seat)
		if at < s.until {
			if b.Len() > 1 {
				b.WriteByte(',')
			}
			b.WriteString(`{"account":` + meta.JSONString(account) +
				`,"lead":` + strconv.FormatBool(s.lead) +
				`,"until":` + jsonInt(s.until) + "}")
		}
		return false
	})
	b.WriteByte(']')
	return b.String()
}

// ApplicationJSON returns null for a collection nobody applied for.
func ApplicationJSON(collection string) string {
	a := applicationOf(collection)
	if a == nil {
		return "null"
	}
	return "{" +
		`"collection":` + meta.JSONString(collection) +
		`,"founder":` + meta.JSONString(a.Founder.String()) +
		`,"statementHash":` + meta.JSONString(a.StatementHash) +
		`,"statementCID":` + meta.JSONString(a.StatementCID) +
		`,"revision":` + jsonInt(a.Revision) +
		`,"status":` + meta.JSONString(a.Status) +
		`,"reviewer":` + meta.JSONString(a.Reviewer.String()) +
		`,"reasonHash":` + meta.JSONString(a.ReasonHash) +
		`,"reasonCID":` + meta.JSONString(a.ReasonCID) +
		`,"updatedAt":` + jsonInt(a.UpdatedAt) + "}"
}

// pageJSON renders a zero-based page of a tree in key order; the page size is
// 1..50.
func pageJSON(tree *avl.Tree, page, size int64, item func(v any) string) string {
	if page < 0 || size < 1 || size > 50 {
		panic("launchpad/curation: invalid page")
	}
	var b strings.Builder
	b.WriteByte('[')
	// page < total comes first so that page*size cannot overflow.
	if total := int64(tree.Size()); page < total && page*size < total {
		tree.IterateByOffset(int(page*size), int(size), func(_ string, v any) bool {
			if b.Len() > 1 {
				b.WriteByte(',')
			}
			b.WriteString(item(v))
			return false
		})
	}
	b.WriteByte(']')
	return b.String()
}

// ApplicationsJSON pages through the applications in order of first filing.
func ApplicationsJSON(page, size int64) string {
	return pageJSON(&filings, page, size, func(v any) string {
		return ApplicationJSON(v.(string))
	})
}

// AccessJSON tells a private inbox what an account is to a collection right
// now: whether it holds the creator role ("founder"), an active manager, and
// whether Conflicted bars it from acting as one. It is public data to be read
// on every request, not a token.
//
// The answer also says where and when it was evaluated: the chain ID, the
// block height and the block time. The answer is not signed: checking them
// exposes an honest node on the wrong chain or behind it, and proves nothing
// against a node that lies. Its eight fields are a contract with that reader.
func AccessJSON(collection, who string) string {
	account := address(who)
	checkAccount(account)
	info := nft.GetInfo(collection)
	return "{" +
		`"chainId":` + meta.JSONString(runtime.ChainID()) +
		`,"height":` + jsonInt(runtime.ChainHeight()) +
		`,"time":` + jsonInt(now()) +
		`,"collection":` + meta.JSONString(collection) +
		`,"account":` + meta.JSONString(who) +
		`,"founder":` + strconv.FormatBool(info.Creator == account) +
		`,"manager":` + strconv.FormatBool(active(account)) +
		`,"conflicted":` + strconv.FormatBool(conflicted(info, account)) + "}"
}

func featureJSON(collection string) string {
	f := featureOf(collection)
	if f == nil {
		return "null"
	}
	return "{" +
		`"proposer":` + meta.JSONString(f.proposer.String()) +
		`,"approver":` + meta.JSONString(f.approver.String()) +
		`,"reasonHash":` + meta.JSONString(f.reasonHash) +
		`,"reasonCID":` + meta.JSONString(f.reasonCID) +
		`,"until":` + jsonInt(f.until) + "}"
}

func holdJSON(collection string) string {
	h := holdOf(collection)
	if h == nil {
		return "null"
	}
	return "{" +
		`"actor":` + meta.JSONString(h.actor.String()) +
		`,"confirmer":` + meta.JSONString(h.confirmer.String()) +
		`,"extended":` + strconv.FormatBool(h.extended) +
		`,"reasonHash":` + meta.JSONString(h.reasonHash) +
		`,"reasonCID":` + meta.JSONString(h.reasonCID) +
		`,"until":` + jsonInt(h.until) + "}"
}

func verificationJSON(collection string) string {
	v := verifications.Get(collection)
	if v == nil {
		return "null"
	}
	r := v.(verification)
	return "{" +
		`"verified":` + strconv.FormatBool(r.verified) +
		`,"reasonHash":` + meta.JSONString(r.reasonHash) +
		`,"reasonCID":` + meta.JSONString(r.reasonCID) +
		`,"updatedAt":` + jsonInt(r.updatedAt) + "}"
}

func appealJSON(key string) string {
	a := appealOf(key)
	if a == nil {
		return "null"
	}
	return "{" +
		`"collection":` + meta.JSONString(a.collection) +
		`,"subject":` + meta.JSONString(a.subject) +
		`,"statementHash":` + meta.JSONString(a.statementHash) +
		`,"statementCID":` + meta.JSONString(a.statementCID) +
		`,"filedAt":` + jsonInt(a.filedAt) +
		`,"open":` + strconv.FormatBool(a.openKey != "") +
		`,"upheld":` + strconv.FormatBool(a.upheld) +
		`,"reasonHash":` + meta.JSONString(a.reasonHash) +
		`,"reasonCID":` + meta.JSONString(a.reasonCID) +
		`,"resolvedAt":` + jsonInt(a.resolvedAt) + "}"
}

// CollectionJSON is a collection's editorial record: what a client may show
// now, then the records behind it and the latest appeal on each subject. A
// part with no record is null.
func CollectionJSON(collection string) string {
	nft.GetInfo(collection)
	var b strings.Builder
	b.WriteString("{" +
		`"collection":` + meta.JSONString(collection) +
		`,"verified":` + strconv.FormatBool(IsVerified(collection)) +
		`,"featured":` + strconv.FormatBool(IsFeatured(collection)) +
		`,"hidden":` + strconv.FormatBool(IsHidden(collection)) +
		`,"verification":` + verificationJSON(collection) +
		`,"feature":` + featureJSON(collection) +
		`,"hold":` + holdJSON(collection) +
		`,"appeals":{`)
	for i, subject := range subjects {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(meta.JSONString(subject) + ":" + appealJSON(collection+"/"+subject))
	}
	b.WriteString("}}")
	return b.String()
}

// AppealsJSON pages through the open appeals in filing order.
func AppealsJSON(page, size int64) string {
	return pageJSON(&openAppeals, page, size, func(v any) string {
		return appealJSON(v.(string))
	})
}

// FeaturesJSON pages through every collection that has a feature slot on
// record, in ID text order, saying whether it is featured right now.
func FeaturesJSON(page, size int64) string {
	return pageJSON(&features, page, size, func(v any) string {
		f := v.(*feature)
		return "{" +
			`"collection":` + meta.JSONString(f.collection) +
			`,"featured":` + strconv.FormatBool(IsFeatured(f.collection)) +
			`,"until":` + jsonInt(f.until) + "}"
	})
}
