package rules

import (
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"
)

func WaterTravelTile(code uint8) bool {
	switch code {
	case 0, 1, 8, 11, 13, 14:
		return true
	default:
		return false
	}
}

func TerrainMoveCost(code uint8) uint64 {
	switch code {
	case 0:
		panic("cannot move through the sea")
	case 3, 4:
		return 2
	case 10:
		return 3
	default:
		return 1
	}
}

func LandTravelBudget(travelBonus uint64) uint64 {
	return 3 + travelBonus
}

func BoatTravelBudget() uint64 { return 8 }

func SavedTravelBonus(budget uint64, spent uint64) uint64 {
	if spent >= budget {
		return 0
	}
	remaining := budget - spent
	if remaining > 1 {
		return 1
	}
	return remaining
}

func HouseBuildCost(housesOnTile uint64) uint64 {
	return 20 + housesOnTile
}

func BoatPearlCost() uint64 { return 1 }

func CanBuyBoatHere(code uint8) bool {
	return code == 11 // fishing village
}

func CanBuildOnTile(code uint8) bool {
	return code != 0
}

func travelNodeIndex(x uint64, y uint64, width uint64) uint64 {
	return y*width + x
}

func LandTravelPath(start types.Position, dest types.Position) (uint64, bool) {
	if types.SameTile(start, dest) {
		return 0, false
	}
	width := book.Width()
	height := book.Height()
	total := width * height
	unreachable := ^uint64(0)
	dist := make([]uint64, total)
	visited := make([]bool, total)
	prev := make([]uint64, total)
	for i := uint64(0); i < total; i++ {
		dist[i] = unreachable
		prev[i] = unreachable
	}
	startIdx := travelNodeIndex(start.X, start.Y, width)
	destIdx := travelNodeIndex(dest.X, dest.Y, width)
	dist[startIdx] = 0

	for {
		bestCost := unreachable
		bestIdx := unreachable
		for idx := uint64(0); idx < total; idx++ {
			if visited[idx] {
				continue
			}
			if dist[idx] < bestCost {
				bestCost = dist[idx]
				bestIdx = idx
			}
		}
		if bestIdx == unreachable {
			break
		}
		if bestIdx == destIdx {
			cursor := destIdx
			leavesBoat := false
			for cursor != unreachable && cursor != startIdx {
				x := cursor % width
				y := cursor / width
				if !WaterTravelTile(book.Tile(x, y)) {
					leavesBoat = true
				}
				cursor = prev[cursor]
			}
			return bestCost, leavesBoat
		}
		visited[bestIdx] = true
		x := bestIdx % width
		y := bestIdx / width
		for dx := int64(-1); dx <= 1; dx++ {
			for dy := int64(-1); dy <= 1; dy++ {
				if dx == 0 && dy == 0 {
					continue
				}
				nxSigned := int64(x) + dx
				nySigned := int64(y) + dy
				if nxSigned < 0 || nySigned < 0 {
					continue
				}
				nx := uint64(nxSigned)
				ny := uint64(nySigned)
				if nx >= width || ny >= height || !book.IsLand(nx, ny) {
					continue
				}
				nextIdx := travelNodeIndex(nx, ny, width)
				candidate := bestCost + TerrainMoveCost(book.Tile(nx, ny))
				if candidate < dist[nextIdx] {
					dist[nextIdx] = candidate
					prev[nextIdx] = bestIdx
				}
			}
		}
	}
	panic("no land route to that tile")
}

func BoatTravelCost(start types.Position, dest types.Position) uint64 {
	if types.SameTile(start, dest) {
		return 0
	}
	if !WaterTravelTile(book.Tile(start.X, start.Y)) || !WaterTravelTile(book.Tile(dest.X, dest.Y)) {
		panic("boat travel requires coastal, harbor, or water tiles")
	}
	width := book.Width()
	height := book.Height()
	total := width * height
	unreachable := ^uint64(0)
	dist := make([]uint64, total)
	queue := make([]uint64, total)
	for i := uint64(0); i < total; i++ {
		dist[i] = unreachable
	}
	startIdx := travelNodeIndex(start.X, start.Y, width)
	destIdx := travelNodeIndex(dest.X, dest.Y, width)
	head := 0
	tail := 0
	dist[startIdx] = 0
	queue[tail] = startIdx
	tail++
	for head < tail {
		idx := queue[head]
		head++
		if idx == destIdx {
			return dist[idx]
		}
		x := idx % width
		y := idx / width
		for dx := int64(-1); dx <= 1; dx++ {
			for dy := int64(-1); dy <= 1; dy++ {
				if dx == 0 && dy == 0 {
					continue
				}
				nxSigned := int64(x) + dx
				nySigned := int64(y) + dy
				if nxSigned < 0 || nySigned < 0 {
					continue
				}
				nx := uint64(nxSigned)
				ny := uint64(nySigned)
				if nx >= width || ny >= height || !WaterTravelTile(book.Tile(nx, ny)) {
					continue
				}
				nextIdx := travelNodeIndex(nx, ny, width)
				if dist[nextIdx] == unreachable {
					dist[nextIdx] = dist[idx] + 1
					queue[tail] = nextIdx
					tail++
				}
			}
		}
	}
	panic("no boat route to that tile")
}

func PlanTravel(
	origin types.Position,
	dest types.Position,
	travelBonus uint64,
	carriesBoat bool,
) types.TravelPlan {
	originCode := book.Tile(origin.X, origin.Y)
	destCode := book.Tile(dest.X, dest.Y)

	landCost := uint64(0)
	landLeavesBoat := false
	landFeasible := false
	if book.IsLand(origin.X, origin.Y) && book.IsLand(dest.X, dest.Y) {
		landCost, landLeavesBoat = LandTravelPath(origin, dest)
		if landCost <= LandTravelBudget(travelBonus) {
			landFeasible = true
		}
	}

	boatCost := uint64(0)
	boatFeasible := false
	if carriesBoat && WaterTravelTile(originCode) && WaterTravelTile(destCode) {
		boatCost = BoatTravelCost(origin, dest)
		if boatCost <= BoatTravelBudget() {
			boatFeasible = true
		}
	}

	if destCode == 0 && !boatFeasible {
		panic("you need a carried boat to travel onto the water")
	}

	if boatFeasible && (!landFeasible || originCode == 0 || destCode == 0 || boatCost < landCost) {
		return types.TravelPlan{UseBoat: true, Cost: boatCost, Budget: BoatTravelBudget(), LeavesBoat: false}
	}
	if landFeasible {
		return types.TravelPlan{UseBoat: false, Cost: landCost, Budget: LandTravelBudget(travelBonus), LeavesBoat: landLeavesBoat}
	}
	panic("that route is not available")
}
