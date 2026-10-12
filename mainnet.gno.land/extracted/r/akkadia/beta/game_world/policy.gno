package game_world

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const (
	SetGameTypePolicyEvent     = "SetGameTypePolicy"
	AddApprovedCreatorEvent    = "AddApprovedCreator"
	RemoveApprovedCreatorEvent = "RemoveApprovedCreator"
	SetApprovedCreatorsEvent   = "SetApprovedCreators"
	approvedCreatorListMax     = 100
	approvedCreatorBatchMax    = 100
	gameTypeMaxLen             = 64
)

var (
	gameTypePolicies *bptree.BPTree
	approvedCreators *bptree.BPTree
)

func init() {
	initializePolicyState()
}

func SetGameTypePolicy(cur realm, gameType string, creationCost int64, mode CreationMode) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertValidGameType(gameType)
	if creationCost < 0 {
		panic("creation cost must not be negative")
	}
	assertValidCreationMode(mode)

	oldValue := gameTypePolicies.Get(gameType)
	old := GameTypePolicy{}
	found := oldValue != nil
	if found {
		old = oldValue.(GameTypePolicy)
	}
	if found && old.CreationCost == creationCost && old.CreationMode == mode {
		return
	}
	gameTypePolicies.Set(gameType, GameTypePolicy{CreationCost: creationCost, CreationMode: mode})
	chain.Emit(
		SetGameTypePolicyEvent,
		"executor", executor.String(),
		"gameType", gameType,
		"oldCreationCost", strconv.FormatInt(old.CreationCost, 10),
		"newCreationCost", strconv.FormatInt(creationCost, 10),
		"oldCreationMode", strconv.Itoa(int(old.CreationMode)),
		"newCreationMode", strconv.Itoa(int(mode)),
	)
}

func AddApprovedCreator(cur realm, gameType string, creator address) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	mustGetGameTypePolicy(gameType)
	assertValidCreator(creator)
	if !setApprovedCreator(gameType, creator, true) {
		return
	}
	chain.Emit(
		AddApprovedCreatorEvent,
		"executor", executor.String(),
		"gameType", gameType,
		"creator", creator.String(),
	)
}

func RemoveApprovedCreator(cur realm, gameType string, creator address) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	mustGetGameTypePolicy(gameType)
	assertValidCreator(creator)
	if !setApprovedCreator(gameType, creator, false) {
		return
	}
	chain.Emit(
		RemoveApprovedCreatorEvent,
		"executor", executor.String(),
		"gameType", gameType,
		"creator", creator.String(),
	)
}

func SetApprovedCreators(cur realm, gameType, creatorsCSV string, approved bool) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	mustGetGameTypePolicy(gameType)
	if creatorsCSV == "" {
		panic("creator list must not be empty")
	}

	requestedCount := 0
	changedCount := 0
	start := 0
	for {
		end := start
		for end < len(creatorsCSV) && creatorsCSV[end] != ',' {
			end++
		}
		requestedCount++
		if requestedCount > approvedCreatorBatchMax {
			panic("creator list exceeds limit")
		}
		creator := address(creatorsCSV[start:end])
		assertValidCreator(creator)
		if setApprovedCreator(gameType, creator, approved) {
			changedCount++
		}
		if end == len(creatorsCSV) {
			break
		}
		start = end + 1
	}
	if changedCount == 0 {
		return
	}
	chain.Emit(
		SetApprovedCreatorsEvent,
		"executor", executor.String(),
		"gameType", gameType,
		"creatorsCSV", creatorsCSV,
		"approved", strconv.FormatBool(approved),
		"requestedCount", strconv.Itoa(requestedCount),
		"changedCount", strconv.Itoa(changedCount),
	)
}

func setApprovedCreator(gameType string, creator address, approved bool) bool {
	set, found := getApprovedCreators(gameType)
	old := found && set.Has(creator.String())
	if old == approved {
		return false
	}
	if approved {
		if !found {
			set = createApprovedCreators(gameType)
		}
		set.Set(creator.String(), true)
	} else {
		set.Remove(creator.String())
	}
	return true
}

func IsApprovedCreator(gameType string, creator address) bool {
	mustGetGameTypePolicy(gameType)
	assertValidCreator(creator)
	return isApprovedCreator(gameType, creator)
}

func GetApprovedCreatorCount(gameType string) int {
	mustGetGameTypePolicy(gameType)
	set, found := getApprovedCreators(gameType)
	if !found {
		return 0
	}
	return set.Size()
}

func ListApprovedCreators(gameType string, offset, count int) []address {
	mustGetGameTypePolicy(gameType)
	if offset < 0 {
		panic("offset must not be negative")
	}
	if count < 1 || count > approvedCreatorListMax {
		panic("count must be between 1 and 100")
	}
	result := []address{}
	set, found := getApprovedCreators(gameType)
	if !found {
		return result
	}
	set.IterateByOffset(offset, count, func(value string, _ any) bool {
		result = append(result, address(value))
		return false
	})
	return result
}

func HasGameTypePolicy(gameType string) bool {
	assertValidGameType(gameType)
	return gameTypePolicies.Has(gameType)
}

func GetGameTypePolicy(gameType string) GameTypePolicy {
	return mustGetGameTypePolicy(gameType)
}

func initializePolicyState() {
	gameTypePolicies = bptree.NewBPTree32()
	approvedCreators = bptree.NewBPTree32()
}

func assertValidGameType(gameType string) {
	if len(gameType) < 1 || len(gameType) > gameTypeMaxLen {
		panic("game type key length must be between 1 and 64")
	}
	for _, ch := range gameType {
		if (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') && ch != '_' && ch != '-' {
			panic("invalid game type key")
		}
	}
}

func mustGetGameTypePolicy(gameType string) GameTypePolicy {
	assertValidGameType(gameType)
	value := gameTypePolicies.Get(gameType)
	if value == nil {
		panic("game type policy not found: " + gameType)
	}
	return value.(GameTypePolicy)
}

func getApprovedCreators(gameType string) (*bptree.BPTree, bool) {
	value := approvedCreators.Get(gameType)
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}

func createApprovedCreators(gameType string) *bptree.BPTree {
	set := bptree.NewBPTree32()
	approvedCreators.Set(gameType, set)
	return set
}

func isApprovedCreator(gameType string, creator address) bool {
	set, found := getApprovedCreators(gameType)
	return found && set.Has(creator.String())
}

func assertValidCreationMode(mode CreationMode) {
	if mode < CreationModeOperatorOnly || mode > CreationModePublicCreator {
		panic("invalid creation mode")
	}
}

func assertValidCreator(creator address) {
	if !creator.IsValid() {
		panic("invalid creator address")
	}
}

func resetGameWorldState() {
	initializePolicyState()
	resetGameWorldStore()
}
