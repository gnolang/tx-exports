package memba_notes_rc1

import (
	"encoding/base64"
	"gno.land/p/samcrew/avl"
	keys "gno.land/r/samcrew/enckeys_v1"
	"strconv"
	"strings"
)

func q(s string) string    { return strconv.Quote(s) }
func u(n uint64) string    { return q(strconv.FormatUint(n, 10)) }
func blob(b []byte) string { return "\"" + base64.StdEncoding.EncodeToString(b) + "\"" }
func noteJSON(n *note, withBody bool) string {
	s := `{"id":` + q(idText(n.ID)) + `,"owner":` + q(string(n.Owner)) + `,"pending_owner":` + q(string(n.PendingOwner)) + `,"owner_generation":` + u(n.OwnerGeneration) + `,"mode":` + strconv.Itoa(int(n.Mode)) + `,"state_revision":` + u(n.Revision) + `,"title_revision":` + u(n.TitleRevision) + `,"body_revision":` + u(n.BodyRevision) + `,"epoch":` + u(uint64(n.Epoch)) + `,"body_bytes":` + q(strconv.Itoa(n.BodyBytes)) + `,"title_blob":` + blob(n.Title) + `,"commitment":` + blob(n.Commitment) + `,"deleted":` + strconv.FormatBool(n.Deleted) + `,"listed":` + strconv.FormatBool(n.Listed && !n.ModeratorHidden) + `,"owner_listed":` + strconv.FormatBool(n.Listed) + `,"moderator_hidden":` + strconv.FormatBool(n.ModeratorHidden) + `,"created_height":` + q(strconv.FormatInt(n.CreatedHeight, 10)) + `,"op_id":` + q(idText(n.Last.Operation)) + `,"executor":` + q(string(n.LastExecutor)) + `,"gov_writers":` + strconv.FormatBool(n.GovWriters) + `,"actor":` + q(string(n.Last.Actor)) + `,"height":` + q(strconv.FormatInt(n.Last.Height, 10))
	if withBody {
		s += `,"body_blob":` + blob(n.Body)
	}
	return s + `}`
}
func NoteJSON(idHex string) string {
	v, ok := notes.Get(idText(readID(idHex)))
	if !ok {
		return "null"
	}
	return noteJSON(v.(*note), true)
}
func page(tree *avl.Tree, prefix, cursor string, limit int) string {
	if limit < 1 || limit > MaxPage {
		panic("notes: page limit")
	}
	if len(cursor) > 53 {
		panic("notes: cursor length")
	}
	if cursor != "" {
		if len(cursor) != 53 || cursor[20] != ':' {
			panic("notes: bad cursor")
		}
		readID(cursor[21:])
		for _, c := range cursor[:20] {
			if c < '0' || c > '9' {
				panic("notes: bad cursor")
			}
		}
	}
	end := prefix + "\xff"
	if cursor != "" {
		end = prefix + cursor
	}
	items := []string{}
	next := ""
	tree.ReverseIterate(prefix, end, func(key string, value interface{}) bool {
		if cursor != "" && key == end {
			return false
		}
		v, ok := notes.Get(value.(string))
		if !ok {
			panic("notes: corrupt index")
		}
		items = append(items, noteJSON(v.(*note), false))
		next = strings.TrimPrefix(key, prefix)
		return len(items) == limit
	})
	if len(items) < limit {
		next = ""
	}
	return `{"items":[` + strings.Join(items, ",") + `],"next_cursor":` + q(next) + `}`
}
func ListByOwnerJSON(addr address, cursor string, limit int) string {
	return page(ownerIndex, string(keys.CanonicalAddress(addr))+":", cursor, limit)
}
func ListPublicJSON(cursor string, limit int) string { return page(publicIndex, "", cursor, limit) }
func ConfigJSON() string {
	return `{"realm":` + q(RealmPath) + `,"admin":` + q(string(admin)) + `,"pending_admin":` + q(string(pendingAdmin)) + `,"treasury":` + q(string(treasury)) + `,"create_fee_ugnot":` + q(strconv.FormatInt(createFee, 10)) + `,"paused":` + strconv.FormatBool(paused) + `}`
}
