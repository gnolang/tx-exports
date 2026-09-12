package kourt2
import (
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
)
const maxFolderTextLen = 200
const (
	maxFolderDepth = 4
	maxFolderItems = 200
	maxFolders = 100
)
type folder struct {
	id     uint64
	name   string
	desc   string
	items  []uint64
	purged bool
	code   string
	retired bool
	bornOf uint64
	focusByDefault bool
	parent uint64
	ord int
	image *mediaItem
}
func (cm *courtMod) folderDepth(id uint64) int {
	d := 0
	for id != 0 && d <= maxFolders {
		d++
		v := cm.folders.Get(beClaimKey(id))
		if v == nil {
			break
		}
		id = v.(*folder).parent
	}
	return d
}
func (cm *courtMod) folderHeight(id uint64) int {
	h := 1
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		f, ok := v.(*folder)
		if !ok || f.parent != id {
			return false
		}
		if ch := 1 + cm.folderHeight(f.id); ch > h {
			h = ch
		}
		return false
	})
	return h
}
func (cm *courtMod) mustNestable(id, parent uint64, height int) {
	if parent == 0 {
		return
	}
	if parent == id {
		panic("kourtv2: a folder cannot contain itself")
	}
	cm.mustFolder(parent)
	for up, n := parent, 0; up != 0 && n <= maxFolders; n++ {
		if up == id {
			panic("kourtv2: that would put a folder inside itself")
		}
		v := cm.folders.Get(beClaimKey(up))
		if v == nil {
			break
		}
		up = v.(*folder).parent
	}
	if cm.folderDepth(parent)+height > maxFolderDepth {
		panic("kourtv2: folders nest at most " + strconv.Itoa(maxFolderDepth) + " deep")
	}
}
func folderAfter(a, b *folder) bool {
	ap, bp := a.ord > 0, b.ord > 0
	if ap != bp {
		return bp
	}
	if ap && a.ord != b.ord {
		return a.ord > b.ord
	}
	return a.id > b.id
}
func (cm *courtMod) folderRows() []*folder {
	out := make([]*folder, 0, maxFolders)
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		if f, ok := v.(*folder); ok {
			out = append(out, f)
		}
		return false
	})
	for i := range out {
		first := true
		for j := 0; j < i; j++ {
			if out[j].parent == out[i].parent {
				first = false
				break
			}
		}
		if !first {
			continue
		}
		p := out[i].parent
		slots := make([]int, 0, len(out))
		grp := make([]*folder, 0, len(out))
		for j, g := range out {
			if g.parent == p {
				slots = append(slots, j)
				grp = append(grp, g)
			}
		}
		for a := 1; a < len(grp); a++ {
			f := grp[a]
			b := a - 1
			for b >= 0 && folderAfter(grp[b], f) {
				grp[b+1] = grp[b]
				b--
			}
			grp[b+1] = f
		}
		for k, g := range grp {
			out[slots[k]] = g
		}
	}
	return out
}
func (cm *courtMod) mustFolder(id uint64) *folder {
	v := cm.folders.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such folder")
	}
	return v.(*folder)
}
func requireFolderMod(c *Court, who address) *courtMod {
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	return cm
}
func folderTextOK(name, desc string) bool {
	return runeLen(name) > 0 && runeLen(name) <= maxFolderTextLen && runeLen(desc) <= maxFolderTextLen
}
func folderNameTaken(cm *courtMod, name string) bool {
	taken := false
	if cm.folders == nil {
		return false
	}
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		f := v.(*folder)
		if !f.retired && f.name == name {
			taken = true
			return true
		}
		return false
	})
	return taken
}
func newFolderCore(cm *courtMod, name, desc string, parent uint64) uint64 {
	if cm.folders.Size() >= maxFolders {
		panic("kourtv2: this court already has " + strconv.Itoa(maxFolders) + " folders")
	}
	if !folderTextOK(name, desc) {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	if parent != 0 {
		cm.mustNestable(0, parent, 1)
	}
	cm.folderSeq++
	id := cm.folderSeq
	cm.folders.Set(beClaimKey(id), &folder{id: id, name: name, desc: desc, parent: parent})
	return id
}
type folderProposal struct {
	id     uint64
	name   string
	desc   string
	parent uint64
	by     address
	at     int64
}
func RegisterFolderProposal(cur realm, courtSlug, name, desc string, parentID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if !folderTextOK(name, desc) {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	if parentID != 0 {
		cm.mustNestable(0, parentID, 1)
	}
	if folderNameTaken(cm, name) {
		panic("kourtv2: this court already has a folder by that name")
	}
	if cm.folderProps == nil {
		cm.folderProps = bptree.NewBPTree32()
	}
	cm.folderPropSeq++
	id := cm.folderPropSeq
	cm.folderProps.Set(beClaimKey(id), &folderProposal{
		id: id, name: name, desc: desc, parent: parentID, by: who, at: heightNow(),
	})
	return id
}
func (cm *courtMod) mustFolderProposal(id uint64) *folderProposal {
	if cm.folderProps == nil {
		panic("kourtv2: no such folder proposal")
	}
	v := cm.folderProps.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such folder proposal")
	}
	return v.(*folderProposal)
}
func CreateFolder(cur realm, courtSlug, name, desc string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	id := newFolderCore(cm, name, desc, 0)
	emitModAct(c.id, 0, "folder-create", who)
	return id
}
func CreateFolderIn(cur realm, courtSlug string, parentID uint64, name, desc string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	id := newFolderCore(cm, name, desc, parentID)
	emitModAct(c.id, 0, "folder-create", who)
	return id
}
func MoveFolder(cur realm, courtSlug string, folderID, newParent uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	cm.mustNestable(folderID, newParent, cm.folderHeight(folderID))
	f.parent = newParent
	emitModAct(c.id, 0, "folder-move", who)
}
func AddToFolder(cur realm, courtSlug string, folderID, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	_ = mustClaim(c, claimID)
	f := cm.mustFolder(folderID)
	fileInto(f, claimID)
	emitModAct(c.id, claimID, "folder-add", who)
}
func fileInto(f *folder, claimID uint64) {
	for _, x := range f.items {
		if x == claimID {
			return
		}
	}
	if len(f.items) >= maxFolderItems {
		panic("kourtv2: a folder holds at most " + strconv.Itoa(maxFolderItems) + " claims")
	}
	f.items = append(f.items, claimID)
}
func RemoveFromFolder(cur realm, courtSlug string, folderID, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	out := f.items[:0]
	found := false
	for _, x := range f.items {
		if x == claimID {
			found = true
			continue
		}
		out = append(out, x)
	}
	if !found {
		panic("kourtv2: that claim is not in the folder")
	}
	f.items = out
	emitModAct(c.id, claimID, "folder-remove", who)
}
func RenameFolder(cur realm, courtSlug string, folderID uint64, name, desc string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if runeLen(name) == 0 || runeLen(name) > maxFolderTextLen || runeLen(desc) > maxFolderTextLen {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: this folder's text was purged and cannot be re-set")
	}
	f.name = name
	f.desc = desc
	emitModAct(c.id, 0, "folder-rename", who)
}
func SetFolderImage(cur realm, courtSlug string, folderID uint64, media string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: this folder's text was purged and cannot be re-set")
	}
	items := parseMediaArg(media)
	if len(items) != 1 {
		panic("kourtv2: a folder carries exactly one image")
	}
	if items[0].kind != mediaKindImage {
		panic("kourtv2: a folder's image is an image, not a video link")
	}
	f.image = &items[0]
	emitModAct(c.id, 0, "folder-image", who)
}
func ClearFolderImage(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	cm.mustFolder(folderID).image = nil
	emitModAct(c.id, 0, "folder-image-clear", who)
}
func FolderImage(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	cm := c.mod
	if cm == nil {
		return "[]"
	}
	f := cm.mustFolder(folderID)
	if f.image == nil {
		return "[]"
	}
	return encodeMedia([]mediaItem{*f.image})
}
func PurgeFolder(cur realm, courtSlug string, folderID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	f := cm.mustFolder(folderID)
	fire, code := approveAction(d.pending, "purgefolder:"+c.id+":"+strconv.FormatUint(folderID, 10), who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	f.purged = true
	f.code = code
	f.name = ""
	f.desc = ""
	f.image = nil
	emitPurge(c.id, 0, code, who)
}
func FolderCount(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.folders.Size()
}
func FolderName(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	f := c.mod.mustFolder(folderID)
	if f.purged {
		return "[purged:" + f.code + "]"
	}
	return f.name
}
func FolderDesc(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	return c.mod.mustFolder(folderID).desc
}
func FolderItems(courtSlug string, folderID uint64) []uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	f := c.mod.mustFolder(folderID)
	out := make([]uint64, len(f.items))
	copy(out, f.items)
	return out
}
func ClaimFolders(courtSlug string, claimID uint64) []uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return nil
	}
	var out []uint64
	for _, f := range c.mod.folderRows() {
		if f.purged {
			continue
		}
		for _, it := range f.items {
			if it == claimID {
				out = append(out, f.id)
				break
			}
		}
	}
	return out
}
func RetireFolder(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if cm.folderHeight(folderID) > 1 {
		panic("kourtv2: retire the folders inside it first")
	}
	f.retired = true
	f.items = nil
	emitModAct(c.id, 0, "folder-retire", who)
}
func RestoreFolder(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: a purged folder cannot be restored")
	}
	f.retired = false
	emitModAct(c.id, 0, "folder-restore", who)
}
func MoveItemInFolder(cur realm, courtSlug string, folderID, claimID uint64, to int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	at := -1
	for i, x := range f.items {
		if x == claimID {
			at = i
			break
		}
	}
	if at < 0 {
		panic("kourtv2: that claim is not in the folder")
	}
	if to < 0 || to >= len(f.items) {
		panic("kourtv2: that position is outside the folder")
	}
	if to == at {
		return
	}
	out := make([]uint64, 0, len(f.items))
	for i, x := range f.items {
		if i == at {
			continue
		}
		if len(out) == to {
			out = append(out, claimID)
		}
		out = append(out, x)
	}
	if len(out) == to {
		out = append(out, claimID)
	}
	f.items = out
	emitModAct(c.id, claimID, "folder-order", who)
}
func OrderFolders(cur realm, courtSlug string, parentID uint64, ids string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if parentID != 0 {
		cm.mustFolder(parentID)
	}
	if len(ids) > maxFolders*21 {
		panic("kourtv2: that is too long to be a list of folder ids")
	}
	sibs := make([]*folder, 0, maxFolders)
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		if f, ok := v.(*folder); ok && f.parent == parentID {
			sibs = append(sibs, f)
		}
		return false
	})
	if len(sibs) == 0 {
		panic("kourtv2: there are no folders under that heading to order")
	}
	parts := strings.Split(ids, ",")
	if len(parts) != len(sibs) {
		panic("kourtv2: that heading holds " + strconv.Itoa(len(sibs)) +
			" folders and the order lists " + strconv.Itoa(len(parts)) +
			"; it must list every one of them, exactly once")
	}
	order := make([]*folder, 0, len(parts))
	for _, p := range parts {
		id, err := strconv.ParseUint(strings.TrimSpace(p), 10, 64)
		if err != nil {
			panic("kourtv2: an order is a comma-separated list of folder ids")
		}
		var f *folder
		for _, s := range sibs {
			if s.id == id {
				f = s
				break
			}
		}
		if f == nil {
			panic("kourtv2: folder " + strconv.FormatUint(id, 10) +
				" is not under that heading")
		}
		for _, x := range order {
			if x.id == id {
				panic("kourtv2: folder " + strconv.FormatUint(id, 10) +
					" is listed twice")
			}
		}
		order = append(order, f)
	}
	for i, f := range order {
		f.ord = i + 1
	}
	emitModAct(c.id, 0, "folder-sort", who)
}
func FolderTree(courtSlug string) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return ""
	}
	var b strings.Builder
	n := 0
	for _, f := range c.mod.folderRows() {
		if n > 0 {
			b.WriteString(",")
		}
		flags := ""
		if f.retired {
			flags += "r"
		}
		if f.purged {
			flags += "p"
		}
		if f.focusByDefault {
			flags += "f"
		}
		if f.image != nil {
			flags += "i"
		}
		if flags == "" {
			flags = "-"
		}
		b.WriteString(strconv.FormatUint(f.id, 10) + ":" +
			strconv.FormatUint(f.parent, 10) + ":" + flags + ":" +
			strconv.FormatUint(f.bornOf, 10))
		n++
	}
	return b.String()
}
func FolderRetired(courtSlug string, folderID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	v := c.mod.folders.Get(beClaimKey(folderID))
	if v == nil {
		return false
	}
	return v.(*folder).retired
}
func FolderParent(courtSlug string, folderID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	v := c.mod.folders.Get(beClaimKey(folderID))
	if v == nil {
		return 0
	}
	return v.(*folder).parent
}
func FolderPurged(courtSlug string, folderID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	return c.mod.mustFolder(folderID).purged
}
