package taletree

// Read API for other realms and off-chain clients (`vm/qeval`). Every
// function returns copies; nothing hands out a pointer into state.

// PassageView is a read-only copy of a passage.
type PassageView struct {
	ID       int
	Tale     int
	Parent   int // 0 for the opening
	Author   address
	Choice   string
	Body     string // empty when the passage is hidden
	Depth    int
	Children []int
	Cheers   int
	Tips     int64
	Ending   bool
	Hidden   bool // the passage or one of its ancestors is hidden
	Height   int64
}

// TaleView is a read-only copy of a tale.
type TaleView struct {
	ID       int
	Title    string
	Narrator address
	Root     int
	Passages int
	Endings  int
	Cheers   int
	Locked   bool
	Height   int64
}

// TaleCount returns the number of tales.
func TaleCount() int { return tales.Size() }

// PassageCount returns the number of passages in all tales.
func PassageCount() int { return passages.Size() }

// BardCount returns the number of distinct writers.
func BardCount() int { return bards.Size() }

// TotalTips returns the ugnot forwarded to authors, all time.
func TotalTips() int64 { return totalTips }

// IsPaused reports whether the keeper paused writing.
func IsPaused() bool { return paused }

// GetTale returns a copy of a tale.
func GetTale(id int) (TaleView, bool) {
	if id <= 0 {
		return TaleView{}, false
	}
	t, ok := getTale(seqidOf(id))
	if !ok {
		return TaleView{}, false
	}
	return TaleView{
		ID:       int(t.ID),
		Title:    t.Title,
		Narrator: t.Narrator,
		Root:     int(t.Root),
		Passages: t.Passages,
		Endings:  t.Endings,
		Cheers:   t.Cheers,
		Locked:   t.Locked,
		Height:   t.Height,
	}, true
}

// GetPassage returns a copy of a passage. The body of a hidden passage
// is left out.
func GetPassage(id int) (PassageView, bool) {
	if id <= 0 {
		return PassageView{}, false
	}
	p, ok := getPassage(seqidOf(id))
	if !ok {
		return PassageView{}, false
	}
	visible := isVisible(p)
	v := PassageView{
		ID:     int(p.ID),
		Tale:   int(p.Tale),
		Parent: int(p.Parent),
		Author: p.Author,
		Choice: p.Choice,
		Depth:  p.Depth,
		Cheers: p.Cheers,
		Tips:   p.Tips,
		Ending: p.Ending,
		Hidden: !visible,
		Height: p.Height,
	}
	if visible {
		v.Body = p.Body
	}
	for _, c := range p.Children {
		v.Children = append(v.Children, int(c))
	}
	return v, true
}

// CanonPath returns the passage ids of a tale's canon, from the opening
// to the last passage readers have chosen.
func CanonPath(taleID int) []int {
	if taleID <= 0 {
		return nil
	}
	t, ok := getTale(seqidOf(taleID))
	if !ok {
		return nil
	}
	var ids []int
	for _, p := range canonPath(t) {
		ids = append(ids, int(p.ID))
	}
	return ids
}

// HasCheered reports whether addr cheered a passage.
func HasCheered(passageID int, addr address) bool {
	if passageID <= 0 {
		return false
	}
	return cheers.Has(seqidOf(passageID).Binary() + addr.String())
}
