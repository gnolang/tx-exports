package hex

import "sort"

// Height is the height of a counter or of a terrain feature for the line
// of sight (rule 31.3, the HEIGHTS table), at ground elevation: a higher
// number is higher on the map. Hill and gully elevations come with the
// boards that have them.
type Height int

const (
	// HeightDown is a DOWN body counter.
	HeightDown Height = 3
	// HeightObstacle is an obstacle (36.3) or a window sill (33.5).
	HeightObstacle Height = 4
	// HeightUpright is an upright counter, a counter on an obstacle (30.32)
	// and a hex aimed at (31.3).
	HeightUpright Height = 5
	// HeightWall is a wall or a treetrunk, higher than anything (33.2, 38.3).
	HeightWall Height = 10
)

// Between returns the obstacle hexes lying between two hexes for the line
// of sight (rule 31): those every string from one hex's printed coordinate
// to the other's passes through (31.2, 36.3), as the generator computed
// them from the board image into the between table. The order of the two
// hexes does not matter. It is nil when nothing lies between them, when
// they are the same hex or when either is unknown, and it never names one
// of the two hexes (36.5).
func (b *Board) Between(from, to string) []string {
	var out []string
	for _, o := range b.obstaclesBetween(b.Index(from), b.Index(to)) {
		out = append(out, b.ids[o])
	}
	return out
}

// obstaclesBetween is Between on indices: the obstacle hexes between ids[i] and
// ids[j], as indices in ids.
func (b *Board) obstaclesBetween(i, j int) []int {
	if i < 0 || j < 0 || i == j {
		return nil
	}
	if i > j {
		i, j = j, i
	}
	// The rows are sorted by (a, b, o): a pair's rows are contiguous.
	k := sort.Search(len(b.between), func(k int) bool {
		r := b.between[k]
		return r[0] > i || (r[0] == i && r[1] >= j)
	})
	var out []int
	for ; k < len(b.between) && b.between[k][0] == i && b.between[k][1] == j; k++ {
		out = append(out, b.obstacles[b.between[k][2]])
	}
	return out
}

// LineOfSight reports whether a character at from, of height hFrom, has a
// clear line of sight to a target at to, of height hTo (rule 31). Every
// obstacle lying between the two hexes is compared with the two heights
// (31.3): it blocks the sight when higher than both and not when lower
// than both (31.31); when it is between the two heights it blocks only if
// the lower end is adjacent to it (31.32; the plateau effect of 31.33
// needs hill or gully hexes, which no board has yet). The aim zone is not
// looked at here: 31.21 is InAimZone. blocker is the first obstacle
// blocking the sight, "" when it is clear or a hex is unknown (which
// blocks).
func (b *Board) LineOfSight(from, to string, hFrom, hTo Height) (clear bool, blocker string) {
	i, j := b.Index(from), b.Index(to)
	if i < 0 || j < 0 {
		return false, ""
	}
	for _, o := range b.obstaclesBetween(i, j) {
		if blocks(HeightObstacle, hFrom, hTo, b.adjacent(i, o), b.adjacent(j, o)) {
			return false, b.ids[o]
		}
	}
	return true, ""
}

// blocks applies rules 31.31 and 31.32 to a feature of height h lying
// between two counters of heights h1 and h2, each adjacent to it or not.
func blocks(h, h1, h2 Height, adj1, adj2 bool) bool {
	switch {
	case h > h1 && h > h2:
		return true // higher than both (31.31)
	case h < h1 && h < h2:
		return false // lower than both (31.31)
	case h1 < h:
		return adj1 // the lower counter blocks the sight when adjacent (31.32)
	case h2 < h:
		return adj2
	}
	return false
}

// adjacent reports whether ids[j] is a neighbour of ids[i].
func (b *Board) adjacent(i, j int) bool {
	for _, n := range b.nbr[i] {
		if n == j {
			return true
		}
	}
	return false
}
