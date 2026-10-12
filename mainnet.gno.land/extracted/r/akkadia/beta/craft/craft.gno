package craft

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
	"gno.land/r/akkadia/beta/equipment"
	"gno.land/r/akkadia/beta/item"
)

const (
	SetRecipeEvent     = "SetRecipe"
	DeleteRecipeEvent  = "DeleteRecipe"
	DeleteRecipesEvent = "DeleteRecipes"
	SetListLimitEvent  = "SetListLimit"
	SetCraftFeeEvent   = "SetCraftFee"
	CraftEvent         = "Craft"
)

var (
	recipes   = bptree.NewBPTree32()
	listLimit = defaultRecipeListLimit
	craftFee  = defaultCraftFee
)

func init() { resetCraftState() }

func resetCraftState() {
	recipes = bptree.NewBPTree32()
	listLimit = defaultRecipeListLimit
	craftFee = defaultCraftFee
}

// SetRecipe stores the item definition ID produced by a canonical recipe.
func SetRecipe(cur realm, recipe string, itemID uint32) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	canonicalRecipe, _ := mustParseRecipe(recipe)
	setRecipe(canonicalRecipe, itemID)
}

// SetRecipes stores up to 100 canonical recipe and item ID pairs in one transaction.
func SetRecipes(cur realm, recipesCSV, itemIDsCSV string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	canonicalRecipes, itemIDs := mustParseRecipeCSV(recipesCSV, itemIDsCSV)
	for i, recipe := range canonicalRecipes {
		setRecipe(recipe, itemIDs[i])
	}
}

func setRecipe(canonicalRecipe string, itemID uint32) {
	recipes.Set(canonicalRecipe, itemID)
	chain.Emit(
		SetRecipeEvent,
		"recipe", canonicalRecipe,
		"itemId", strconv.FormatUint(uint64(itemID), 10),
	)
}

func DeleteRecipe(cur realm, recipe string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	canonicalRecipe := mustCanonicalRecipe(recipe)
	deleteRecipe(canonicalRecipe)
	chain.Emit(DeleteRecipeEvent, "recipe", canonicalRecipe)
}

func DeleteRecipes(cur realm, recipesCSV string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	canonicalRecipes := mustParseRecipeKeyCSV(recipesCSV)
	for _, recipe := range canonicalRecipes {
		if !recipes.Has(recipe) {
			panic("recipe not found: " + recipe)
		}
	}
	for _, recipe := range canonicalRecipes {
		deleteRecipe(recipe)
	}
	chain.Emit(DeleteRecipesEvent, "count", strconv.Itoa(len(canonicalRecipes)))
}

func deleteRecipe(canonicalRecipe string) {
	if _, removed := recipes.Remove(canonicalRecipe); !removed {
		panic("recipe not found: " + canonicalRecipe)
	}
}

func HasRecipe(recipe string) bool {
	canonical, _, errMsg := parseRecipe(recipe)
	if errMsg != "" {
		return false
	}
	return recipes.Has(canonical)
}

func GetRecipe(recipe string) uint32 {
	return mustGetRecipeItemID(mustCanonicalRecipe(recipe))
}

func GetRecipeCount() int {
	return recipes.Size()
}

func ListRecipes(page, count int) []map[string]string {
	assertRecipeListPageCount(page, count)
	result := []map[string]string{}
	recipes.IterateByOffset((page-1)*count, count, func(recipe string, value any) bool {
		result = append(result, map[string]string{
			"recipe": recipe,
			"itemId": strconv.FormatUint(uint64(value.(uint32)), 10),
		})
		return false
	})
	return result
}

func SetListLimit(cur realm, limit int) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	if limit < 1 {
		panic("limit must be at least 1")
	}

	oldLimit := listLimit
	listLimit = limit
	chain.Emit(
		SetListLimitEvent,
		"oldLimit", strconv.Itoa(oldLimit),
		"newLimit", strconv.Itoa(limit),
	)
}

func GetListLimit() int {
	return listLimit
}

func SetCraftFee(cur realm, fee int64) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCraftNoCoins()
	if fee < 0 {
		panic("fee must be non-negative")
	}

	oldFee := craftFee
	craftFee = fee
	chain.Emit(
		SetCraftFeeEvent,
		"oldFee", strconv.FormatInt(oldFee, 10),
		"newFee", strconv.FormatInt(fee, 10),
	)
}

func GetCraftFee() int64 {
	return craftFee
}

// Craft burns a canonical recipe and mints the next GRC721 equipment token.
func Craft(cur realm, recipe string) uint64 {
	caller := accesscontrol.MustGetUserCaller(0, cur)
	canonicalRecipe, ingredients := mustParseRecipe(recipe)
	itemID := mustGetRecipeItemID(canonicalRecipe)
	assertExactUgnotPayment(craftFee)

	for _, ingredient := range ingredients {
		item.BurnFromRealm(cross(cur), caller, ingredient.TokenID, ingredient.Amount)
	}
	tokenID := equipment.MintFromRealm(cross(cur), caller, itemID, "", "")
	if craftFee > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), admin.GetFeeCollector(), chain.Coins{{"ugnot", craftFee}})
	}

	chain.Emit(
		CraftEvent,
		"owner", caller.String(),
		"recipe", canonicalRecipe,
		"equipmentTokenId", strconv.FormatUint(tokenID, 10),
		"itemId", strconv.FormatUint(uint64(itemID), 10),
		"fee", strconv.FormatInt(craftFee, 10),
	)
	return tokenID
}

func mustCanonicalRecipe(recipe string) string {
	canonical, _ := mustParseRecipe(recipe)
	return canonical
}

func mustGetRecipeItemID(recipe string) uint32 {
	value := recipes.Get(recipe)
	if value == nil {
		panic("recipe not found: " + recipe)
	}
	return value.(uint32)
}

func assertCraftNoCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
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
