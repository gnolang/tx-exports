package kourt2
import (
	"strconv"
	"strings"
	"chain"
)
const (
	setMark   = "\U00013080"
	shutMark  = "\U0001307C"
	setPrefix = setMark + " "
	shutPrefix = shutMark + " "
)
func parseSetTitle(title string) (name string, shown bool, ok bool) {
	pre := ""
	switch {
	case strings.HasPrefix(title, setPrefix):
		pre, shown = setPrefix, true
	case strings.HasPrefix(title, shutPrefix):
		pre, shown = shutPrefix, false
	default:
		return "", false, false
	}
	name = title[len(pre):]
	if !folderTextOK(name, "") {
		return "", false, false
	}
	return name, shown, true
}
func IsSetClaim(courtSlug string, claimID uint64) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	_, _, ok := parseSetTitle(cs.title)
	return ok
}
func ClaimSet(courtSlug string, claimID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil || c.mod.folders == nil {
		return 0
	}
	var out uint64
	c.mod.folders.Iterate("", "", func(_ string, v any) bool {
		f := v.(*folder)
		if f.bornOf == claimID {
			out = f.id
			return true
		}
		return false
	})
	return out
}
func SetBornOf(courtSlug string, folderID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.mustFolder(folderID).bornOf
}
func New(cur realm, courtSlug string, claimID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	name, shown, ok := parseSetTitle(cs.title)
	if !ok {
		panic("kourtv2: this claim's title is not a set heading")
	}
	if cs.verdictAt == 0 || cs.provClose {
		panic("kourtv2: no final verdict")
	}
	if cs.provisional != 0 {
		panic("kourtv2: the verdict was not YES")
	}
	if prior := ClaimSet(courtSlug, claimID); prior != 0 {
		panic("kourtv2: this claim already carries set " + strconv.FormatUint(prior, 10))
	}
	cm := ensureMod(c)
	if folderNameTaken(cm, name) {
		panic("kourtv2: a folder by that name already exists")
	}
	var parent uint64
	if in := ClaimFolders(courtSlug, claimID); len(in) == 1 {
		parent = in[0]
	} else if len(in) > 1 {
		panic("kourtv2: this claim is filed in more than one set; a born set needs exactly one parent")
	}
	if parent != 0 && cm.mustFolder(parent).retired {
		panic("kourtv2: the set this claim is filed in has been retired")
	}
	fid := newFolderCore(cm, name, "", parent)
	f := cm.mustFolder(fid)
	f.bornOf = claimID
	f.focusByDefault = shown
	emitModAct(c.id, claimID, "new", cs.author)
	chain.Emit("SetAffirmed",
		"court", c.id,
		"claim", strconv.FormatUint(claimID, 10),
		"folder", strconv.FormatUint(fid, 10),
		"parent", strconv.FormatUint(parent, 10),
		"name", name,
		"height", eventHeight(),
	)
	return fid
}
