package craft

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/equipment"
	"gno.land/r/akkadia/beta/item"
)

func TestSetRecipeCreatesAndUpdatesRecipe(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))

	SetRecipe(cross(cur), "0001|minecraft:iron_ingot:01", 100)
	uassert.True(t, HasRecipe("0001|minecraft:iron_ingot:1"))
	uassert.True(t, HasRecipe("0001|minecraft:iron_ingot:01"))
	uassert.True(t, HasRecipe("0001|0:minecraft:iron_ingot:1"))
	uassert.Equal(t, uint32(100), GetRecipe("0001|minecraft:iron_ingot:01"))
	uassert.Equal(t, 1, GetRecipeCount())

	SetRecipe(cross(cur), "0001|0:minecraft:iron_ingot:1", 101)
	uassert.Equal(t, uint32(101), GetRecipe("0001|minecraft:iron_ingot:1"))
	uassert.Equal(t, 1, GetRecipeCount())

	SetRecipe(cross(cur), "000A|craft-hex-a:1|craft-hex-b:2", 102)
	uassert.True(t, HasRecipe("000a|craft-hex-a:1|craft-hex-b:2"))
	uassert.Equal(t, uint32(102), GetRecipe("000A|craft-hex-a:1|craft-hex-b:2"))
	uassert.Equal(t, 2, GetRecipeCount())
}

func TestSetRecipeRequiresDirectAdminWithoutCoins(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-security-item:1"

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetRecipe(cross(cur), recipe, 200)
	})
	uassert.False(t, HasRecipe(recipe))

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/craft_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetRecipe(cross(cur), recipe, 200)
	})
	uassert.False(t, HasRecipe(recipe))

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() {
		SetRecipe(cross(cur), recipe, 200)
	})
	testing.SetOriginSend(chain.Coins{})
	uassert.False(t, HasRecipe(recipe))
}

func TestSetRecipesStoresMultipleRecipes(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))

	SetRecipes(
		cross(cur),
		"0001|craft-batch-iron:1,0002|craft-batch-gold:2",
		"300,301",
	)

	uassert.Equal(t, uint32(300), GetRecipe("0001|craft-batch-iron:1"))
	uassert.Equal(t, uint32(301), GetRecipe("0002|craft-batch-gold:2"))
}

func TestSetRecipesStoresOccupancyBatch(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))

	SetRecipes(
		cross(cur),
		"0013|test-iron:1|test-iron:2|test-stick:2,"+
			"0003|test-wood:2|test-stone:1,"+
			"0001|test-herb:3,"+
			"0007|test-copper:1|test-leather:2|test-cloth:1",
		"1101000,1101001,1101002,1101003",
	)

	uassert.Equal(t, 4, GetRecipeCount())
	uassert.Equal(t, uint32(1101000), GetRecipe("0013|test-iron:1|test-iron:2|test-stick:2"))
	uassert.Equal(t, uint32(1101001), GetRecipe("0003|test-wood:2|test-stone:1"))
	uassert.Equal(t, uint32(1101002), GetRecipe("0001|test-herb:3"))
	uassert.Equal(t, uint32(1101003), GetRecipe("0007|test-copper:1|test-leather:2|test-cloth:1"))
	uassert.True(t, HasRecipe("0013|0:test-iron:1|1:test-iron:2|4:test-stick:2"))
	uassert.Equal(t, 4, len(ListRecipes(1, 20)))
}

func TestSetRecipesAllowsLastDuplicateToWin(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	recipe := "0001|craft-batch-duplicate:1"

	SetRecipes(cross(cur), recipe+","+recipe, "310,311")

	uassert.Equal(t, uint32(311), GetRecipe(recipe))
}

func TestSetRecipesRequiresDirectAdmin(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-batch-security:1"

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetRecipes(cross(cur), recipe, "320")
	})
	uassert.False(t, HasRecipe(recipe))

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/craft_batch_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetRecipes(cross(cur), recipe, "320")
	})
	uassert.False(t, HasRecipe(recipe))
}

func TestSetRecipesRejectsCountMismatchAndRollsBack(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	firstRecipe := "0001|craft-mismatch-a:1"
	secondRecipe := "0001|craft-mismatch-b:1"

	uassert.AbortsWithMessage(t, cur, "recipes and item ids count mismatch", func() {
		SetRecipes(cross(cur), firstRecipe+","+secondRecipe, "400")
	})

	uassert.False(t, HasRecipe(firstRecipe))
	uassert.False(t, HasRecipe(secondRecipe))
}

func TestSetRecipesRejectsInvalidItemID(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	recipe := "0001|craft-invalid-id:1"

	uassert.AbortsWithMessage(t, cur, "invalid item id: invalid", func() {
		SetRecipes(cross(cur), recipe, "invalid")
	})
	uassert.False(t, HasRecipe(recipe))
}

func TestSetRecipesRejectsEmptyTokensAndTrailingComma(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	recipe := "0001|craft-empty-token:1"

	uassert.AbortsWithMessage(t, cur, "empty recipe not allowed", func() {
		SetRecipes(cross(cur), recipe+",", "410,411")
	})
	uassert.False(t, HasRecipe(recipe))

	uassert.AbortsWithMessage(t, cur, "empty item id not allowed", func() {
		SetRecipes(cross(cur), recipe+",0001|craft-empty-id:1", "412,")
	})
	uassert.False(t, HasRecipe(recipe))
}

func TestSetRecipesRejectsBatchAboveLimit(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	recipe := "0001|craft-batch-limit:1"
	recipesCSV := recipe
	itemIDsCSV := "500"
	for i := 1; i < 101; i++ {
		recipesCSV += "," + recipe
		itemIDsCSV += ",500"
	}

	uassert.AbortsWithMessage(t, cur, "recipes exceeds 100", func() {
		SetRecipes(cross(cur), recipesCSV, itemIDsCSV)
	})
	uassert.False(t, HasRecipe(recipe))
}

func TestDeleteRecipeRemovesRecipe(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	recipe := "0001|craft-delete-item:1"
	SetRecipe(cross(cur), recipe, 600)

	DeleteRecipe(cross(cur), "0001|craft-delete-item:01")
	uassert.False(t, HasRecipe(recipe))
	uassert.Equal(t, 0, GetRecipeCount())
}

func TestDeleteRecipesRemovesBatchAndRequiresAdmin(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	firstRecipe := "0001|craft-delete-a:1"
	secondRecipe := "0002|craft-delete-b:1"
	SetRecipe(cross(cur), firstRecipe, 601)
	SetRecipe(cross(cur), secondRecipe, 602)

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		DeleteRecipes(cross(cur), firstRecipe)
	})
	uassert.True(t, HasRecipe(firstRecipe))

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	DeleteRecipes(cross(cur), firstRecipe+","+secondRecipe)
	uassert.False(t, HasRecipe(firstRecipe))
	uassert.False(t, HasRecipe(secondRecipe))
}

func TestDeleteRecipesRejectsMissingAndRollsBack(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	firstRecipe := "0001|craft-delete-missing-a:1"
	secondRecipe := "0002|craft-delete-missing-b:1"
	SetRecipe(cross(cur), firstRecipe, 603)
	SetRecipe(cross(cur), secondRecipe, 604)

	uassert.AbortsWithMessage(t, cur, "recipe not found: 0001|0:craft-delete-missing-c:1", func() {
		DeleteRecipes(cross(cur), firstRecipe+",0001|craft-delete-missing-c:1")
	})
	uassert.True(t, HasRecipe(firstRecipe))
	uassert.True(t, HasRecipe(secondRecipe))
}

func TestDeleteRecipeRejectsMissingRecipe(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	uassert.AbortsWithMessage(t, cur, "recipe not found: 0001|0:craft-missing-delete:1", func() {
		DeleteRecipe(cross(cur), "0001|craft-missing-delete:1")
	})
}

func TestListRecipesPagesAndCopiesRows(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), "0001|craft-list-a:1", 701)
	SetRecipe(cross(cur), "0002|craft-list-b:1", 702)
	SetRecipe(cross(cur), "0004|craft-list-c:1", 703)

	uassert.Equal(t, 3, GetRecipeCount())
	page1 := ListRecipes(1, 2)
	uassert.Equal(t, 2, len(page1))
	page1[0]["itemId"] = "hacked"
	uassert.Equal(t, "701", ListRecipes(1, 2)[0]["itemId"])
	page2 := ListRecipes(2, 2)
	uassert.Equal(t, 1, len(page2))
	uassert.Equal(t, 0, len(ListRecipes(3, 2)))

	uassert.PanicsWithMessage(t, cur, "page must be at least 1", func() {
		ListRecipes(0, 1)
	})
	uassert.PanicsWithMessage(t, cur, "count must be at least 1", func() {
		ListRecipes(1, 0)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 100)", func() {
		ListRecipes(1, 101)
	})
}

func TestSetListLimit(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetListLimit(cross(cur), 1)
	uassert.Equal(t, 1, GetListLimit())
	uassert.PanicsWithMessage(t, cur, "count exceeds listLimit (max: 1)", func() {
		ListRecipes(1, 2)
	})

	uassert.AbortsWithMessage(t, cur, "limit must be at least 1", func() {
		SetListLimit(cross(cur), 0)
	})

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetListLimit(cross(cur), 50)
	})
}

func TestMustParseRecipeCanonicalizesSlotsAndCountsIngredients(cur realm, t *testing.T) {
	canonical, ingredients := mustParseRecipe("0013|minecraft:iron_ingot:01|minecraft:iron_ingot:2|minecraft:stick:3")

	uassert.Equal(t, "0013|0:minecraft:iron_ingot:1|1:minecraft:iron_ingot:2|4:minecraft:stick:3", canonical)
	uassert.Equal(t, 3, len(ingredients))
	uassert.Equal(t, uint(0), ingredients[0].Slot)
	uassert.Equal(t, "minecraft:iron_ingot", ingredients[0].TokenID)
	uassert.Equal(t, int64(1), ingredients[0].Amount)
	uassert.Equal(t, uint(4), ingredients[2].Slot)
	uassert.Equal(t, "minecraft:stick", ingredients[2].TokenID)
	uassert.Equal(t, int64(3), ingredients[2].Amount)

	roundTrip, _ := mustParseRecipe(canonical)
	uassert.Equal(t, canonical, roundTrip)

	hexCanonical, hexIngredients := mustParseRecipe("000A|craft-hex-a:1|craft-hex-b:2")
	uassert.Equal(t, "000a|1:craft-hex-a:1|3:craft-hex-b:2", hexCanonical)
	uassert.Equal(t, uint(1), hexIngredients[0].Slot)
	uassert.Equal(t, uint(3), hexIngredients[1].Slot)
}

func TestMustParseRecipeRejectsInvalidRecipes(cur realm, t *testing.T) {
	tests := []struct {
		recipe, panicMsg string
	}{
		{"", "invalid recipe"},
		{"0000|item:1", "invalid recipe occupancy"},
		{"0001|item", "invalid recipe ingredient"},
		{"0001|item:0", "ingredient amount must be positive"},
		{"0003|item:1", "occupied slots and ingredients count mismatch"},
		{"0001|1:item:1", "ingredient slot mismatch"},
		{"0013|4:stick:1|0:iron:1|1:iron:1", "ingredient slot mismatch"},
		{"0001|%zz:1", "invalid item token id"},
	}

	for _, tc := range tests {
		recipe, panicMsg := tc.recipe, tc.panicMsg
		uassert.PanicsWithMessage(t, cur, panicMsg, func() {
			mustParseRecipe(recipe)
		})
	}
}

func TestHasRecipeReturnsFalseForInvalidAndMissingRecipes(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	uassert.False(t, HasRecipe(""))
	uassert.False(t, HasRecipe("not-a-recipe"))
	uassert.False(t, HasRecipe("0001|craft-missing-query:1"))
	uassert.PanicsWithMessage(t, cur, "recipe not found: 0001|0:craft-missing-query:1", func() {
		GetRecipe("0001|craft-missing-query:1")
	})
}

func TestCraftBurnsItemsAndMintsEquipment(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0013|craft-success-iron:1|craft-success-iron:2|craft-success-stick:2"

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101000)
	mintCraftItem(cross(cur), "craft-success-iron", 3)
	mintCraftItem(cross(cur), "craft-success-stick", 2)

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	before := equipment.GetLatestTokenID()
	collectorBefore := ugnotBalanceForTest(craftTest.FeeCollector)
	realmBefore := ugnotBalanceForTest(craftTest.PkgAddr)
	payCraftFee(defaultCraftFeeCoins())
	tokenID := Craft(cross(cur), "0013|craft-success-iron:01|craft-success-iron:2|craft-success-stick:2")
	uassert.Equal(t, before+1, tokenID)
	uassert.Equal(t, int64(0), item.BalanceOf(craftTest.Owner, "craft-success-iron"))
	uassert.Equal(t, int64(0), item.BalanceOf(craftTest.Owner, "craft-success-stick"))
	uassert.Equal(t, craftTest.Owner, equipment.OwnerOf(tokenID))
	uassert.Equal(t, "1101000", equipment.GetMetadata(tokenID)["definitionId"])
	uassert.Equal(t, defaultCraftFee, ugnotBalanceForTest(craftTest.FeeCollector)-collectorBefore)
	uassert.Equal(t, realmBefore, ugnotBalanceForTest(craftTest.PkgAddr))
}

func TestCraftAllocatesSequentialEquipmentTokenIDs(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-skip-id:1"

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101003)
	mintCraftItem(cross(cur), "craft-skip-id", 2)
	before := equipment.GetLatestTokenID()
	equipment.Mint(cross(cur), craftTest.Other, 1101998, "", "")

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	payCraftFee(defaultCraftFeeCoins())
	tokenID := Craft(cross(cur), recipe)
	uassert.Equal(t, before+2, tokenID)
	uassert.Equal(t, craftTest.Other, equipment.OwnerOf(before+1))
	uassert.Equal(t, craftTest.Owner, equipment.OwnerOf(tokenID))
}

func TestCraftRequiresEquipmentMinterRealm(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-mint-rollback:2"

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101001)
	mintCraftItem(cross(cur), "craft-mint-rollback", 2)
	equipment.UnsetMinterRealm(cross(cur), "gno.land/r/akkadia/beta/craft")

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		payCraftFee(defaultCraftFeeCoins())
		Craft(cross(cur), recipe)
	})
}

func TestCraftRequiresItemMinterRealm(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-item-minter:1"

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101005)
	mintCraftItem(cross(cur), "craft-item-minter", 1)
	item.UnsetMinterRealm(cross(cur), "gno.land/r/akkadia/beta/craft")

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "minter realm required", func() {
		payCraftFee(defaultCraftFeeCoins())
		Craft(cross(cur), recipe)
	})

	uassert.Equal(t, int64(1), item.BalanceOf(craftTest.Owner, "craft-item-minter"))
}

func TestCraftRejectsUnknownRecipeAndInsufficientItems(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-fail-item:2"

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "recipe not found: 0001|0:craft-fail-item:2", func() {
		Craft(cross(cur), recipe)
	})
	uassert.AbortsWithMessage(t, cur, "invalid recipe", func() {
		Craft(cross(cur), "bad")
	})

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101004)
	mintCraftItem(cross(cur), "craft-fail-item", 1)

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "item burn amount exceeds supply", func() {
		payCraftFee(defaultCraftFeeCoins())
		Craft(cross(cur), recipe)
	})
	uassert.Equal(t, int64(1), item.BalanceOf(craftTest.Owner, "craft-fail-item"))
}

func TestCraftRequiresDirectUserAndExactFee(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-craft-security:1"
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101002)
	before := equipment.GetLatestTokenID()

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/craft_craft_relay"))
	uassert.AbortsWithMessage(t, cur, "contract calls not allowed: function must be called directly by user", func() {
		Craft(cross(cur), recipe)
	})

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 1000000ugnot, got ", func() {
		Craft(cross(cur), recipe)
	})
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 1000000ugnot, got 1ugnot", func() {
		payCraftFee(chain.Coins{{"ugnot", 1}})
		Craft(cross(cur), recipe)
	})
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, before, equipment.GetLatestTokenID())
}

func TestCraftRejectsInexactPayment(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	recipe := "0001|craft-inexact-fee:1"
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), recipe, 1101006)
	mintCraftItem(cross(cur), "craft-inexact-fee", 3)
	before := equipment.GetLatestTokenID()

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 1000000ugnot, got 999999ugnot", func() {
		payCraftFee(chain.Coins{{"ugnot", 999_999}})
		Craft(cross(cur), recipe)
	})
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 1000000ugnot, got 1000001ugnot", func() {
		payCraftFee(chain.Coins{{"ugnot", 1_000_001}})
		Craft(cross(cur), recipe)
	})
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 1000000ugnot, got 1000000ugnot,1foo", func() {
		payCraftFee(chain.Coins{{"ugnot", defaultCraftFee}, {"foo", 1}})
		Craft(cross(cur), recipe)
	})
	uassert.Equal(t, before, equipment.GetLatestTokenID())
	uassert.Equal(t, int64(3), item.BalanceOf(craftTest.Owner, "craft-inexact-fee"))
}

func TestSetCraftFeeUpdatesFeeAndAllowsFreeCraft(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	uassert.Equal(t, defaultCraftFee, GetCraftFee())

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetCraftFee(cross(cur), 2_000_000)
	uassert.Equal(t, int64(2_000_000), GetCraftFee())
	SetCraftFee(cross(cur), 0)
	uassert.Equal(t, int64(0), GetCraftFee())

	recipe := "0001|craft-free-fee:1"
	SetRecipe(cross(cur), recipe, 1101007)
	mintCraftItem(cross(cur), "craft-free-fee", 1)

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected no coins, got 1ugnot", func() {
		payCraftFee(chain.Coins{{"ugnot", 1}})
		Craft(cross(cur), recipe)
	})
	collectorBefore := ugnotBalanceForTest(craftTest.FeeCollector)
	payCraftFee(chain.Coins{})
	tokenID := Craft(cross(cur), recipe)
	uassert.Equal(t, craftTest.Owner, equipment.OwnerOf(tokenID))
	uassert.Equal(t, collectorBefore, ugnotBalanceForTest(craftTest.FeeCollector))
}

func TestSetCraftFeeRequiresDirectAdminWithoutCoins(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	uassert.Equal(t, defaultCraftFee, GetCraftFee())

	testing.SetOriginCaller(craftTest.Owner)
	testing.SetRealm(testing.NewUserRealm(craftTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetCraftFee(cross(cur), 50)
	})
	uassert.Equal(t, defaultCraftFee, GetCraftFee())

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/craft_fee_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() {
		SetCraftFee(cross(cur), 50)
	})
	uassert.Equal(t, defaultCraftFee, GetCraftFee())

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() {
		SetCraftFee(cross(cur), 50)
	})
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, defaultCraftFee, GetCraftFee())

	uassert.AbortsWithMessage(t, cur, "fee must be non-negative", func() {
		SetCraftFee(cross(cur), -1)
	})
	uassert.Equal(t, defaultCraftFee, GetCraftFee())
}
