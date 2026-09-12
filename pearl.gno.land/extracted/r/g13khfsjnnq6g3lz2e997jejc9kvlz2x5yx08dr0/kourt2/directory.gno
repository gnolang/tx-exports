package kourt2
import "strconv"
const (
	tierHidden   uint8 = 0
	tierListed   uint8 = 1
	tierFeatured uint8 = 2
)
var directoryAdmin address
func SetTier(cur realm, courtSlug string, tier int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may set a court's tier")
	}
	if tier < int(tierHidden) || tier > int(tierFeatured) {
		panic("kourtv2: tier is 0 (hidden), 1 (listed), or 2 (featured)")
	}
	c := mustCourt(courtSlug)
	if c.tier == uint8(tier) {
		return
	}
	c.tier = uint8(tier)
	emitGlobalAct(c.id, 0, "tier:"+strconv.Itoa(tier), who)
}
func DirectoryAdmin() address        { return directoryAdmin }
func CourtTier(courtSlug string) int { return int(mustCourt(courtSlug).tier) }
func ListCourts() []string {
	out := []string{}
	courts.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}
func ListByTier(tier int) []string {
	out := []string{}
	courts.Iterate("", "", func(key string, v any) bool {
		if int(v.(*Court).tier) == tier {
			out = append(out, key)
		}
		return false
	})
	return out
}
