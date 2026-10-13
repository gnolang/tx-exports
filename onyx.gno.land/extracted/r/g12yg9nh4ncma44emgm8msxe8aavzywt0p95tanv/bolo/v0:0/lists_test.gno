package bolo

import (
	"math"
	"strings"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

func TestPageSize(t *testing.T) {
	for size, want := range map[int]int{math.MinInt: 1, -5: 1, 0: 1, 1: 1, 20: 20, 50: 50, 51: 50, math.MaxInt: 50} {
		if got := pageSize(size); got != want {
			t.Errorf("pageSize(%d) = %d, want %d", size, got, want)
		}
	}
}

func TestPageOffset(t *testing.T) {
	for _, k := range []struct {
		page, size, n, want int
		ok                  bool
	}{
		{1, 10, 25, 0, true},
		{3, 10, 25, 20, true},
		{0, 10, 25, 0, true}, // below 1 reads as 1
		{-7, 10, 25, 0, true},
		{4, 10, 25, 0, false}, // past the end
		{math.MaxInt, 50, 25, 0, false},
		{1, 10, 0, 0, true}, // an empty tree has an empty first page
	} {
		got, ok := pageOffset(k.page, k.size, k.n)
		if got != k.want || ok != k.ok {
			t.Errorf("pageOffset(%d, %d, %d) = %d, %t; want %d, %t", k.page, k.size, k.n, got, ok, k.want, k.ok)
		}
	}
}

// indexCampaigns stores n campaigns, IDs first to first+n-1, as CreateCampaign leaves
// them — in campaigns and every campaign index — organized by org for ben, in the
// category "animals", and returns them with what removes them again.
func indexCampaigns(first seqid.ID, n int, org, ben address) ([]*campaign, func()) {
	var cs []*campaign
	for i := 0; i < n; i++ {
		c := testCampaign(first+seqid.ID(i), modeEscrow, 0)
		c.category, c.organizer, c.beneficiary = "animals", org, ben
		key := c.id.Binary()
		campaigns.Set(key, c)
		addActive(c)
		byOrganizer.Set(org.String()+"/"+key, true)
		byBeneficiary.Set(ben.String()+"/"+key, true)
		cs = append(cs, c)
	}
	return cs, func() {
		for _, c := range cs {
			key := c.id.Binary()
			campaigns.Remove(key)
			dropActive(c)
			byOrganizer.Remove(c.organizer.String() + "/" + key)
			byBeneficiary.Remove(c.beneficiary.String() + "/" + key)
		}
	}
}

// pageAll follows a list's cursor to its end, at most 100 calls, and returns every
// ID seen, in order, with the number of calls.
func pageAll(list func(after string) ([]CampaignView, string)) ([]string, int) {
	var ids []string
	after, calls := "", 0
	for calls < 100 {
		views, next := list(after)
		calls++
		for _, v := range views {
			ids = append(ids, v.ID)
		}
		if next == "" {
			break
		}
		after = next
	}
	return ids, calls
}

// TestListCursor: a list paged to its end by cursor returns every campaign once,
// newest first; next is "" exactly at the end (API §4).
func TestListCursor(t *testing.T) {
	org, ben := testutils.TestAddress("listorg"), testutils.TestAddress("listben")
	_, unindex := indexCampaigns(9901, 7, org, ben)
	defer unindex()
	want := "9907 9906 9905 9904 9903 9902 9901"
	for name, list := range map[string]func(string) ([]CampaignView, string){
		"ListCampaigns":     func(a string) ([]CampaignView, string) { return ListCampaigns(a, 3, "animals") },
		"ListByOrganizer":   func(a string) ([]CampaignView, string) { return ListByOrganizer(org, a, 3) },
		"ListByBeneficiary": func(a string) ([]CampaignView, string) { return ListByBeneficiary(ben, a, 3) },
	} {
		ids, calls := pageAll(list)
		if got := strings.Join(ids, " "); got != want || calls != 3 {
			t.Errorf("%s: %q in %d calls, want %q in 3", name, got, calls, want)
		}
	}
	// A full last page knows it is last: the list peeks one entry further.
	if views, next := ListByOrganizer(org, "9904", 3); len(views) != 3 || next != "" {
		t.Errorf("the last full page: %d views, next %q", len(views), next)
	}
	if views, next := ListByOrganizer(org, "", 3); len(views) != 3 || next != "9905" {
		t.Errorf("the first page: %d views, next %q", len(views), next)
	}
	for _, after := range []string{"042", "+42", " 42", "x", "9901/1"} {
		if !panicsWith(func() { ListByOrganizer(org, after, 3) }, ErrNotFound) {
			t.Errorf("after %q: not ErrNotFound", after)
		}
	}
}

// TestListCampaignsPassed (Q6): a campaign past a deadline nobody recorded is left
// out; one call reads at most four times size entries, so a page can come back short
// or empty while next isn't "", and no campaign repeats or goes missing.
func TestListCampaignsPassed(t *testing.T) {
	org, ben := testutils.TestAddress("listorg"), testutils.TestAddress("listben")
	cs, unindex := indexCampaigns(9911, 9, org, ben)
	defer unindex()
	for _, c := range cs[2:7] { // 9913–9917 are past their deadline, unrecorded
		c.deadline = now() - 1
	}
	if views, next := ListCampaigns("9918", 1, "animals"); len(views) != 0 || next != "9914" {
		t.Errorf("after 9918, size 1: %d views, next %q; want none, read up to 9914", len(views), next)
	}
	ids, _ := pageAll(func(a string) ([]CampaignView, string) { return ListCampaigns(a, 1, "animals") })
	if got := strings.Join(ids, " "); got != "9919 9918 9912 9911" {
		t.Errorf("paged to the end: %q", got)
	}
	// The other lists keep every campaign, closed and past a deadline included.
	ids, _ = pageAll(func(a string) ([]CampaignView, string) { return ListByOrganizer(org, a, 50) })
	if len(ids) != 9 {
		t.Errorf("ListByOrganizer: %d campaigns, want 9", len(ids))
	}
}

// TestListRanges: an address's range stops at the "/" after it, so an address that is
// the start of a real one finds nothing (C12); a delisted campaign stays on its
// organizer's and beneficiary's lists, off ListCampaigns; ListByDonor holds only the
// campaigns an address gave to without anonymity.
func TestListRanges(t *testing.T) {
	org, ben := testutils.TestAddress("listorg"), testutils.TestAddress("listben")
	cs, unindex := indexCampaigns(9921, 3, org, ben)
	defer unindex()
	if views, next := ListByOrganizer(address(org.String()[:20]), "", 50); len(views) != 0 || next != "" {
		t.Errorf("a prefix of the organizer's address: %d views", len(views))
	}
	if views, _ := ListByOrganizer(ben, "", 50); len(views) != 0 {
		t.Errorf("the beneficiary as organizer: %d views", len(views))
	}

	delisted := cs[1]
	delisted.state.listed = false
	dropActive(delisted)
	defer addActive(delisted) // unindex drops it again
	if views, _ := ListCampaigns("", 50, "animals"); len(views) != 2 {
		t.Errorf("ListCampaigns with one delisted: %d views", len(views))
	}
	for name, views := range map[string][]CampaignView{
		"ListByOrganizer":   first(ListByOrganizer(org, "", 50)),
		"ListByBeneficiary": first(ListByBeneficiary(ben, "", 50)),
	} {
		if len(views) != 3 || views[1].Listed || views[1].ID != "9922" {
			t.Errorf("%s: %d views, the delisted one %v", name, len(views), views[1].Listed)
		}
	}

	public, anonymous := testutils.TestAddress("listpublic"), testutils.TestAddress("listanon")
	key := public.String() + "/" + cs[0].id.Binary()
	byDonor.Set(key, true)
	defer byDonor.Remove(key)
	if views, _ := ListByDonor(public, "", 50); len(views) != 1 || views[0].ID != "9921" {
		t.Errorf("ListByDonor, a public donor: %d views", len(views))
	}
	if views, _ := ListByDonor(anonymous, "", 50); len(views) != 0 {
		t.Errorf("ListByDonor, a donor whose gifts were all anonymous: %d views", len(views))
	}
}

func first(views []CampaignView, _ string) []CampaignView { return views }

// TestCampaignLists: a campaign's receipts, withdrawals, refunds and updates, newest
// first, by page number; a refund's donor blanked when all their gifts were anonymous.
func TestCampaignLists(t *testing.T) {
	c := testCampaign(9931, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	public, anonymous := testutils.TestAddress("listpublic"), testutils.TestAddress("listanon")
	c.contributions.Set(public.String(), &contribution{amount: 30, public: true})
	c.contributions.Set(anonymous.String(), &contribution{amount: 20})
	for i := 1; i <= 5; i++ {
		seq := seqid.ID(i)
		c.receipts.Set(seq.Binary(), &receipt{seq: uint64(i), donor: public, amount: int64(i)})
		c.withdrawals.Set(seq.Binary(), &withdrawal{seq: uint64(i), amount: int64(10 * i)})
		c.updates.Set(seq.Binary(), &update{seq: uint64(i), body: "update " + itoa(int64(i))})
	}
	c.refunds.Set(seqid.ID(1).Binary(), &refund{seq: 1, amount: 3, donor: public, kind: windowOpen})
	c.refunds.Set(seqid.ID(2).Binary(), &refund{seq: 2, amount: 2, donor: anonymous, kind: windowOpen})

	seqs := func(n []int64) string {
		var out []string
		for _, s := range n {
			out = append(out, itoa(s))
		}
		return strings.Join(out, " ")
	}
	receipts := func(page, size int) string {
		var n []int64
		for _, v := range ListReceipts(id, page, size) {
			n = append(n, v.Seq)
		}
		return seqs(n)
	}
	for _, k := range []struct {
		page, size int
		want       string
	}{
		{1, 2, "5 4"}, {2, 2, "3 2"}, {3, 2, "1"}, {4, 2, ""}, {0, 2, "5 4"}, {-1, 2, "5 4"},
		{1, 0, "5"}, {1, 1000, "5 4 3 2 1"}, {math.MaxInt, 2, ""},
	} {
		if got := receipts(k.page, k.size); got != k.want {
			t.Errorf("ListReceipts(page %d, size %d) = %q, want %q", k.page, k.size, got, k.want)
		}
	}
	if w := ListWithdrawals(id, 1, 2); len(w) != 2 || w[0].Seq != 5 || w[0].Amount != 50 {
		t.Errorf("ListWithdrawals: %v", w)
	}
	if u := ListUpdates(id, 2, 3); len(u) != 2 || u[0].Seq != 2 || u[0].Body != "update 2" {
		t.Errorf("ListUpdates, page 2: %v", u)
	}
	r := ListRefunds(id, 1, 50)
	if len(r) != 2 || r[0].Seq != 2 || r[0].Donor != "" || r[1].Donor != public || r[1].Kind != windowOpen {
		t.Errorf("ListRefunds: %v", r)
	}
}

// TestGetStats reads the counters the writes keep (API §2.4); the writes are counted
// in z_stats_filetest.gno.
func TestGetStats(t *testing.T) {
	saved := stats
	defer func() { stats = saved }()
	stats = statsState{open: 3, settled: 2}
	s := GetStats()
	if s.Campaigns != campaigns.Size() || s.Open != 3 || s.Settled != 2 {
		t.Errorf("GetStats: %v", s)
	}
}

// TestListCrafted: an address or a category holding "/" can't make a list read a key
// that isn't one of its own entries — it finds nothing, and never panics unkeyed.
func TestListCrafted(t *testing.T) {
	org, ben := testutils.TestAddress("listorg"), testutils.TestAddress("listben")
	cs, unindex := indexCampaigns(0x2f00, 1, org, ben) // its key's seventh byte is "/"
	defer unindex()
	bin := cs[0].id.Binary()
	crafted := address(org.String() + "/" + bin[:6])
	if views, next := ListByOrganizer(crafted, "", 50); len(views) != 0 || next != "" {
		t.Errorf("an address ending in a key's first bytes: %d views", len(views))
	}
	if views, _ := ListCampaigns("", 50, "animals/"+bin[:6]); len(views) != 0 {
		t.Errorf("a category ending in a key's first bytes: %d views", len(views))
	}
}

// TestListCraftedAddress: an address or a category ending in "/" and a key's bytes
// names nothing, so its list comes back empty (C12). Campaigns 47 and 48 end their keys
// in "/" and "0", which a reverse traversal's inclusive end would reach.
func TestListCraftedAddress(t *testing.T) {
	org, ben := testutils.TestAddress("listorg"), testutils.TestAddress("listben")
	_, unindex := indexCampaigns(47, 2, org, ben)
	defer unindex()
	tail := "/\x00\x00\x00\x00\x00\x00\x00"
	for name, list := range map[string]func() ([]CampaignView, string){
		"organizer":   func() ([]CampaignView, string) { return ListByOrganizer(address(org.String()+tail), "", 50) },
		"beneficiary": func() ([]CampaignView, string) { return ListByBeneficiary(address(ben.String()+tail), "", 50) },
		"category":    func() ([]CampaignView, string) { return ListCampaigns("", 50, "animals"+tail) },
	} {
		if views, next := list(); len(views) != 0 || next != "" {
			t.Errorf("%s: %d views, next %q", name, len(views), next)
		}
	}
}

// TestListRangeStops: an organizer's list holds its own campaigns only, though another
// organizer's entries sort right after them.
func TestListRangeStops(t *testing.T) {
	org, later := testutils.TestAddress("listorg"), testutils.TestAddress("listpub")
	if org.String() >= later.String() {
		t.Fatalf("fixture: %s must sort before %s", org, later)
	}
	_, unindex := indexCampaigns(9951, 2, org, org)
	defer unindex()
	_, unindex2 := indexCampaigns(9953, 2, later, later)
	defer unindex2()
	if views, next := ListByOrganizer(org, "", 50); len(views) != 2 || next != "" {
		t.Errorf("ListByOrganizer: %d views, next %q; want 2, \"\"", len(views), next)
	}
}
