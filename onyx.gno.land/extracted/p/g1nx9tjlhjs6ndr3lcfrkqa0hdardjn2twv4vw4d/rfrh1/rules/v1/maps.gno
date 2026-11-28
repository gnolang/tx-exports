package rules

import "strconv"

// Map is an immutable board layout: size plus point-symmetric obstacles.
// It is fully identified by (W, H, Seed, Density).
type Map struct {
	w, h    int
	seed    uint32
	density int
	wall    []bool
}

// Cell contents of a board.
const (
	Empty  = 0
	Wall   = 1
	TrailA = 2
	TrailB = 3
)

const (
	MinSize = 8
	MaxSize = 40
)

// NewMap builds the map for the given size, seed and obstacle density (number
// of obstacle pairs). W and H must be even and within [MinSize, MaxSize].
// Seed 0 or density 0 gives an empty board. If a seed produces a board where
// the two starts are not connected, the next seed is tried (up to 32 times),
// so every map is playable.
func NewMap(w, h int, seed uint32, density int) Map {
	if w%2 != 0 || h%2 != 0 || w < MinSize || h < MinSize || w > MaxSize || h > MaxSize {
		panic("rules: map size must be even and within bounds")
	}
	if density < 0 || density > w*h/8 {
		panic("rules: density out of range")
	}
	m := Map{w: w, h: h, seed: seed, density: density}
	if seed == 0 || density == 0 {
		m.wall = make([]bool, w*h)
		return m
	}
	s := seed
	for try := 0; try < 32; try++ {
		m.wall = generate(w, h, s, density)
		if connected(m) {
			return m
		}
		s++
		if s == 0 {
			s = 1
		}
	}
	m.wall = make([]bool, w*h)
	return m
}

func (m Map) W() int       { return m.w }
func (m Map) H() int       { return m.h }
func (m Map) Seed() uint32 { return m.seed }
func (m Map) Density() int { return m.density }
func (m Map) Wall(x, y int) bool {
	if x < 0 || y < 0 || x >= m.w || y >= m.h {
		return true
	}
	return m.wall[y*m.w+x]
}

// Start returns the starting cell and facing of a side. Side B is side A
// rotated 180 degrees about the board centre.
func (m Map) Start(side int) (Point, Dir) {
	a := Point{2, m.h / 2}
	if side == SideA {
		return a, Right
	}
	return m.rot(a), Left
}

// rot rotates a point 180 degrees about the board centre.
func (m Map) rot(p Point) Point { return Point{m.w - 1 - p.X, m.h - 1 - p.Y} }

// Key is a compact text id used in match strings, e.g. "24x24s7d6".
func (m Map) Key() string {
	return strconv.Itoa(m.w) + "x" + strconv.Itoa(m.h) + "s" + strconv.FormatUint(uint64(m.seed), 10) + "d" + strconv.Itoa(m.density)
}

func xorshift(s uint32) uint32 {
	s ^= s << 13
	s ^= s >> 17
	s ^= s << 5
	return s
}

func generate(w, h int, seed uint32, density int) []bool {
	wall := make([]bool, w*h)
	m := Map{w: w, h: h}
	a, _ := m.Start(SideA)
	b, _ := m.Start(SideB)
	s := seed
	placed := 0
	for guard := 0; placed < density && guard < density*20; guard++ {
		s = xorshift(s)
		x := int(s % uint32(w))
		s = xorshift(s)
		y := int(s % uint32(h))
		p := Point{x, y}
		q := m.rot(p)
		if reserved(p, a) || reserved(p, b) || reserved(q, a) || reserved(q, b) {
			continue
		}
		if wall[y*w+x] {
			continue
		}
		wall[y*w+x] = true
		wall[q.Y*w+q.X] = true
		placed++
	}
	return wall
}

// reserved keeps each start and the cells around and ahead of it free.
func reserved(p, start Point) bool {
	ddx := p.X - start.X
	if ddx < 0 {
		ddx = -ddx
	}
	ddy := p.Y - start.Y
	if ddy < 0 {
		ddy = -ddy
	}
	return ddx <= 3 && ddy <= 1
}

// connected reports whether the two starts are joined by free cells.
func connected(m Map) bool {
	a, _ := m.Start(SideA)
	b, _ := m.Start(SideB)
	seen := make([]bool, m.w*m.h)
	queue := []Point{a}
	seen[a.Y*m.w+a.X] = true
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		if p == b {
			return true
		}
		for d := Dir(0); d < 4; d++ {
			n := p.Step(d)
			if m.Wall(n.X, n.Y) || seen[n.Y*m.w+n.X] {
				continue
			}
			seen[n.Y*m.w+n.X] = true
			queue = append(queue, n)
		}
	}
	return false
}
