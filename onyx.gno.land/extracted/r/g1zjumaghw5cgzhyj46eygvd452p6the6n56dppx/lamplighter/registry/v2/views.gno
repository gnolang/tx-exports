package registry

import (
	"time"
)

// Exists reports whether a job is registered and has not been cancelled. A
// job that runs once still exists after its run, until its owner cancels it.
func Exists(id uint64) bool {
	return jobs.Has(key(id))
}

// Done reports whether a job that runs once has had its run.
func Done(id uint64) bool {
	j, ok := jobs.Get(key(id)).(*job)
	return ok && j.done
}

// IsDue reports whether Exec would currently be accepted for a job.
func IsDue(id uint64) bool {
	j, ok := jobs.Get(key(id)).(*job)
	return ok && notRunnable(j, time.Now().Unix()) == ""
}

// NextDue returns the unix time from which a job's next run is accepted, or
// 0 if the job does not exist.
func NextDue(id uint64) int64 {
	if j, ok := jobs.Get(key(id)).(*job); ok {
		return j.nextDue
	}
	return 0
}

// Balance returns the ugnot a job holds, or 0 if the job does not exist.
func Balance(id uint64) int64 {
	if j, ok := jobs.Get(key(id)).(*job); ok {
		return j.balance
	}
	return 0
}

// Reward returns the ugnot a job pays per run, or 0 if the job does not exist.
func Reward(id uint64) int64 {
	if j, ok := jobs.Get(key(id)).(*job); ok {
		return j.reward
	}
	return 0
}

// Owner returns the package path of the realm that registered a job, or ""
// if the job does not exist.
func Owner(id uint64) string {
	if j, ok := jobs.Get(key(id)).(*job); ok {
		return j.owner
	}
	return ""
}

// DueJobs lists jobs Exec would currently accept, the longest overdue first,
// as comma-separated "id:reward:due" entries, at most limit of them (capped at
// MaxPage). It is what an executor polls.
//
// To read on from a full page, pass the due time and id of its last entry as
// afterDue and afterID; pass 0 and 0 for the first page. Paging by position
// rather than by count means a reader never pays again for the entries it has
// already seen, however many jobs sit at the head of the list.
//
// It reads the queue index, so its cost depends on how many jobs it returns,
// not on how many are registered.
func DueJobs(afterDue int64, afterID uint64, limit int) string {
	if limit <= 0 || limit > MaxPage {
		limit = MaxPage
	}

	start := ""
	if afterDue > 0 || afterID > 0 {
		if afterDue < 0 {
			afterDue = 0
		}
		start = dueKey(afterDue, afterID) + "0" // the smallest key above that entry's own
	}
	// Every due key below this one has nextDue <= now; parked jobs sort above it.
	end := dueKey(time.Now().Unix()+1, 0)

	out := ""
	taken := 0
	queue.Iterate(start, end, func(_ string, v any) bool {
		j := v.(*job)
		if out != "" {
			out += ","
		}
		out += utoa(j.id) + ":" + itoa(j.reward) + ":" + itoa(j.nextDue)
		taken++
		return taken >= limit
	})
	return out
}

// recentSize is how many past runs the registry remembers.
const recentSize = 8

// run is one past execution, kept for the dashboard.
type run struct {
	job    uint64
	by     address
	at     int64 // unix time; 0 marks a slot that has never been used
	reward int64
}

// recent is a ring of the last runs. Whoever sends a transaction pays a
// storage deposit for every byte of state it adds, so a table with one row
// per executor would charge each newcomer for their own row. The ring is
// allocated in full when the realm is deployed and a run overwrites a slot in
// place, so that recording a run does not grow the state by a row.
var (
	recent     [recentSize]run
	recentNext int
)

// initRecent fills every slot with an address, so that the first runs do not
// each grow the state by one.
func initRecent(placeholder address) {
	for i := range recent {
		recent[i].by = placeholder
	}
}

// remember records a run in the ring, overwriting the oldest one.
func remember(id uint64, by address, at, reward int64) {
	r := &recent[recentNext]
	r.job = id
	r.by = by
	r.at = at
	r.reward = reward
	recentNext = (recentNext + 1) % recentSize
}

// recentRuns returns the remembered runs, newest first.
func recentRuns() []run {
	out := make([]run, 0, recentSize)
	for i := 1; i <= recentSize; i++ {
		r := recent[(recentNext-i+recentSize)%recentSize]
		if r.at != 0 {
			out = append(out, r)
		}
	}
	return out
}
