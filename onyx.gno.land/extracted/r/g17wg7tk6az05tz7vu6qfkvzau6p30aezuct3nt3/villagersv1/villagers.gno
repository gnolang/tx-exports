// Package villagers holds The Joint's collectible villagers: GRC721 tokens
// with two traits, a job, loyalty and three needs that decay over game hours.
// Only the town realm (its path is set once by the admin) can mint villagers
// and change their needs; owners move them with the GRC721 calls below.
// Needs are settled lazily: a record keeps the needs at NeedsAt and reads
// project them forward with townmath.Decay.
package villagersv1

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
)

// Starting values of a new villager.
const (
	StartLoyalty int64 = 3
	MaxLoyalty   int64 = 10
	StartNeed    int64 = 8000
)

// MaxHour is the largest game hour the restricted functions accept (about
// 317 years at 10 seconds per game hour).
const MaxHour int64 = 1_000_000_000

// MaxPage is the largest page Villagers returns.
const MaxPage = 50

// idWidth is the zero-padded width of record keys, so the tree orders
// villagers by numeric id.
const idWidth = 12

// noKeyAdmin is used only when init sees an empty deployer address, which
// happens in the gno test VM (package init runs with an empty caller) and
// never on chain. It is the raw bytes "noadmin_____________", not derived
// from any public key, so nobody can sign as it. Tests act as admin through
// Admin().
const noKeyAdmin address = "g1dehkzerdd9h97h6lta047h6lta047h6l4mazdj"

// Villager is one villager's record. ID is the GRC721 token id (a decimal
// string). Traits are two distinct trait indexes. Needs are the needs at
// game hour NeedsAt.
type Villager struct {
	ID      string
	Seed    uint64
	Job     int64
	Loyalty int64
	Traits  [2]int
	Needs   townmath.Needs
	NeedsAt int64
}

var (
	admin    *ownable.Ownable
	townPath string
	token    *grc721.Token
	ledger   *grc721.PrivateLedger
	teller   grc721.Teller
	records  avl.Tree // zero-padded id -> *Villager
	lastID   int64    // the last id minted; ids start at 1
)

func init(cur realm) {
	deployer := cur.Previous().Address()
	if deployer == "" {
		deployer = noKeyAdmin
	}
	admin = ownable.NewWithAddress(deployer)
	token, ledger = grc721.NewToken("The Joint Villager", "TJV", 0, cur)
	teller = ledger.CallerTeller()
}

// Admin returns the admin address (the deployer).
func Admin() address {
	return admin.Owner()
}

// SetTown stores the town realm's package path, the only caller allowed to
// use the restricted functions. Admin only; it can be called once. The path
// must be a realm path (prefix "gno.land/r/").
func SetTown(cur realm, path string) {
	if !admin.OwnedBy(cur.Previous().Address()) {
		panic("villagers: admin only")
	}
	assertNoSend()
	if path == "" {
		panic("villagers: town path is empty")
	}
	if !strings.HasPrefix(path, "gno.land/r/") {
		panic("villagers: town must be a realm path")
	}
	if townPath != "" {
		panic("villagers: town already set")
	}
	townPath = path
}

// GetTown returns the stored town path ("" before SetTown).
func GetTown() string {
	return townPath
}

// Count returns the number of villagers.
func Count() int {
	return records.Size()
}

// GetVillager returns a copy of a villager's record. Aborts for an unknown id.
func GetVillager(id string) Villager {
	return *mustGet(id)
}

// NeedsNow projects a villager's needs to hoursNow with its traits; nothing
// is stored. An hour before NeedsAt counts as 0 elapsed hours.
func NeedsNow(id string, hoursNow int64) townmath.Needs {
	return needsAt(mustGet(id), hoursNow)
}

// MoodNow is townmath.Mood of NeedsNow.
func MoodNow(id string, hoursNow int64) int {
	return townmath.Mood(needsAt(mustGet(id), hoursNow))
}

// OwnerOf returns a villager's owner. Aborts for an unknown id.
func OwnerOf(id string) address {
	mustGet(id)
	owner, err := token.OwnerOf(grc721.TokenID(id))
	if err != nil {
		panic("villagers: " + err.Error())
	}
	return owner
}

// Villagers returns copies of up to count villagers (clamped to 1..50)
// starting at offset (negative counts as 0), ordered by id.
func Villagers(offset, count int) []Villager {
	if offset < 0 {
		offset = 0
	}
	if count < 1 {
		count = 1
	}
	if count > MaxPage {
		count = MaxPage
	}
	n := records.Size() - offset
	if n <= 0 {
		return []Villager{}
	}
	if n > count {
		n = count
	}
	out := make([]Villager, 0, n)
	records.IterateByOffset(offset, n, func(_ string, value any) bool {
		out = append(out, *value.(*Villager))
		return false
	})
	return out
}

// TransferFrom moves a villager from `from` to `to`. The signer must own it
// or be approved for it. A wallet pop-up is expected: NFT moves are never
// batched.
func TransferFrom(cur realm, from, to address, id string) {
	assertNoSend()
	if err := teller.TransferFrom(0, cur, from, to, grc721.TokenID(id)); err != nil {
		panic("villagers: " + err.Error())
	}
}

// Approve lets `to` transfer one villager (the zero address revokes).
func Approve(cur realm, to address, id string) {
	assertNoSend()
	if err := teller.Approve(0, cur, to, grc721.TokenID(id)); err != nil {
		panic("villagers: " + err.Error())
	}
}

// SetApprovalForAll lets operator transfer all of the signer's villagers.
func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNoSend()
	if err := teller.SetApprovalForAll(0, cur, operator, approved); err != nil {
		panic("villagers: " + err.Error())
	}
}

// needsAt projects v's needs to hoursNow (no write). An hour at or before
// NeedsAt counts as 0 elapsed hours. NeedsAt is in 0..MaxHour, so the
// subtraction runs only when hoursNow > NeedsAt >= 0 and cannot overflow.
func needsAt(v *Villager, hoursNow int64) townmath.Needs {
	elapsed := int64(0)
	if hoursNow > v.NeedsAt {
		elapsed = hoursNow - v.NeedsAt
	}
	return townmath.Decay(v.Needs, CombinedMods(v.Traits), elapsed)
}

// keyOf returns the record key of a canonical id (decimal, 1..12 digits,
// no leading zero), or false.
func keyOf(id string) (string, bool) {
	if len(id) == 0 || len(id) > idWidth || id[0] == '0' {
		return "", false
	}
	for i := 0; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return "", false
		}
	}
	return "000000000000"[len(id):] + id, true
}

// idOf formats a sequential id.
func idOf(n int64) string {
	return strconv.FormatInt(n, 10)
}

// mustGet returns the stored record of id. Callers must not leak the pointer.
func mustGet(id string) *Villager {
	key, ok := keyOf(id)
	if !ok {
		panic("villagers: no such villager")
	}
	v := records.Get(key)
	if v == nil {
		panic("villagers: no such villager")
	}
	return v.(*Villager)
}

// assertNoSend rejects attached coins on functions that do not take payment;
// without it coins sent by mistake would be stuck in the realm.
func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("villagers: this function takes no coins")
	}
}
