package memba_gov

// The publication roster (GOV-1, owner decision Q1 = A, 2026-10-06).
// Seated: the members whose key has signed on gnoland-1. Invited: the other
// founding members; each seat counts only once its own key calls Join.
// Read on gnoland-1 at h628189 (node_info.network checked): each seated
// address is re-derived from the account's own public key; ghost and dadidou
// are at sequence 0 with no key.

type seat struct {
	id     string
	addr   address
	weight int
}

var seedSeated = []seat{
	{"zxxma", "g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c", 2},
	{"mikecito", "g1cvr48r7l7lkmvp77cr6zg2zhu26jgfwr0y8pew", 1},
	{"david", "g1rayfgklwl0aspz488wvrcrvt7t2quy6q06lgk2", 1},
	{"lours", "g1nvxz94ukmggfx4mlldwae3cpde99qmldtcgm9u", 1},
	{"mikael", "g1lyejwwmxef5tn8nx69saykmgm8rlr4xq9yeh3z", 1},
}

var seedInvited = []seat{
	{"ghost", "g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv", 1},
	{"dadidou", "g1jjeuv48j3pmsmnvga8jwfnc2amfyv9c30zx04y", 1},
}
