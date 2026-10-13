package bolo

// statsState holds Bolo-wide counters (API §2.4), kept as things happen, never by
// walking the campaigns. Gift and refund totals aren't kept: an indexer sums them.
type statsState struct {
	open    int // campaigns whose close isn't recorded yet
	settled int // campaigns settled
}

var stats statsState

// StatsView is what GetStats returns (API §2.4).
type StatsView struct {
	Campaigns, Open, Settled int
}

// GetStats returns Bolo-wide figures (API §4). Open counts a campaign past a deadline
// nobody recorded until someone does (§3.1).
func GetStats() StatsView {
	return StatsView{Campaigns: campaigns.Size(), Open: stats.open, Settled: stats.settled}
}
