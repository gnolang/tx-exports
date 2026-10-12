package game_world

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

const (
	CreateGameWorldEvent   = "CreateGameWorld"
	RestrictGameWorldEvent = "RestrictGameWorld"
)

type CreationMode int

const (
	CreationModeInvalid CreationMode = iota
	CreationModeOperatorOnly
	CreationModeApprovedCreator
	CreationModePublicCreator
)

type GameWorldStatus int

const (
	GameWorldStatusInvalid GameWorldStatus = iota
	GameWorldStatusExists
	GameWorldStatusRestricted
)

type GameWorld struct {
	ID               uint64
	Owner            address
	GameType         string
	Status           GameWorldStatus
	CreatedHeight    int64
	RestrictedHeight int64
}

type GameTypePolicy struct {
	CreationCost int64
	CreationMode CreationMode
}

func CreateGameWorld(cur realm, gameType string) uint64 {
	owner := accesscontrol.MustGetUserCaller(0, cur)
	policy := mustGetGameTypePolicy(gameType)
	assertCreationAllowed(gameType, owner, policy.CreationMode)
	assertExactUgnotPayment(policy.CreationCost)

	id := createGameWorld(owner, gameType)
	if policy.CreationCost > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), admin.GetFeeCollector(), chain.Coins{{"ugnot", policy.CreationCost}})
	}
	emitCreateGameWorld(owner, id, gameType, policy.CreationCost)
	return id
}

func RestrictGameWorld(cur realm, gameWorldID uint64) {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	world := GetGameWorld(gameWorldID)
	if world.Status == GameWorldStatusRestricted {
		return
	}
	world.Status = GameWorldStatusRestricted
	world.RestrictedHeight = runtime.ChainHeight()
	gameWorlds.Set(uint64Key(gameWorldID), world)
	removeOwnerGameWorldID(world.Owner, gameWorldID)
	restrictedGameWorldIDs.Set(uint64Key(gameWorldID), true)
	chain.Emit(
		RestrictGameWorldEvent,
		"executor", executor.String(),
		"id", strconv.FormatUint(gameWorldID, 10),
		"oldStatus", strconv.Itoa(int(GameWorldStatusExists)),
		"newStatus", strconv.Itoa(int(GameWorldStatusRestricted)),
		"restrictedHeight", strconv.FormatInt(world.RestrictedHeight, 10),
	)
}

func HasGameWorld(gameWorldID uint64) bool { return gameWorlds.Has(uint64Key(gameWorldID)) }

func GetGameWorld(gameWorldID uint64) GameWorld {
	value := gameWorlds.Get(uint64Key(gameWorldID))
	if value == nil {
		panic("game world not found: " + strconv.FormatUint(gameWorldID, 10))
	}
	return value.(GameWorld)
}

func GetLatestGameWorldID() uint64 { return latestGameWorldID }

func GetListLimit() int { return gameWorldListLimit }

func GetRestrictedGameWorldCount() int { return restrictedGameWorldIDs.Size() }

func ListRestrictedGameWorldIDs(page, count int) []uint64 {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 || count > gameWorldListLimit {
		panic("count must be between 1 and 100")
	}
	result := []uint64{}
	restrictedGameWorldIDs.IterateByOffset((page-1)*count, count, func(key string, _ any) bool {
		result = append(result, parseUint64Key(key))
		return false
	})
	return result
}

func ListLatestGameWorldsByOwner(owner address) []GameWorld {
	ids, found := getOwnerGameWorldIDs(owner)
	if !found {
		return []GameWorld{}
	}
	offset := ids.Size() - gameWorldListLimit
	if offset < 0 {
		offset = 0
	}
	result := []GameWorld{}
	ids.IterateByOffset(offset, gameWorldListLimit, func(key string, _ any) bool {
		result = append(result, GetGameWorld(parseUint64Key(key)))
		return false
	})
	return result
}

func createGameWorld(owner address, gameType string) uint64 {
	if latestGameWorldID == uint64(18446744073709551615) {
		panic("game world id exhausted")
	}
	latestGameWorldID++
	id := latestGameWorldID
	gameWorlds.Set(uint64Key(id), GameWorld{
		ID:            id,
		Owner:         owner,
		GameType:      gameType,
		Status:        GameWorldStatusExists,
		CreatedHeight: runtime.ChainHeight(),
	})
	addOwnerGameWorldID(owner, id)
	return id
}

func assertCreationAllowed(gameType string, creator address, mode CreationMode) {
	switch mode {
	case CreationModeOperatorOnly:
		if !admin.IsAdmin(creator) && !admin.IsOperator(creator) {
			panic("game type creation is operator only")
		}
	case CreationModeApprovedCreator:
		if !isApprovedCreator(gameType, creator) {
			panic("creator is not approved for game type")
		}
	case CreationModePublicCreator:
		return
	default:
		panic("invalid creation mode")
	}
}

func assertExactUgnotPayment(expected int64) {
	coins := unsafe.OriginSend()
	if expected == 0 {
		if len(coins) != 0 {
			panic("exact payment required: expected no coins, got " + coins.String())
		}
		return
	}
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount != expected {
		panic("exact payment required: expected " + strconv.FormatInt(expected, 10) + "ugnot, got " + coins.String())
	}
}

func emitCreateGameWorld(owner address, id uint64, gameType string, creationCost int64) {
	chain.Emit(
		CreateGameWorldEvent,
		"executor", owner.String(),
		"id", strconv.FormatUint(id, 10),
		"owner", owner.String(),
		"gameType", gameType,
		"creationCost", strconv.FormatInt(creationCost, 10),
		"createdHeight", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}
