package craft

import (
	"net/url"
	"strconv"
)

const (
	recipeBatchLimit             = 100
	maxRecipeIngredients         = 16
	defaultRecipeListLimit       = 100
	defaultCraftFee        int64 = 1_000_000
)

type craftIngredient struct {
	Slot    uint
	TokenID string
	Amount  int64
}

func mustParseRecipeCSV(recipesCSV, itemIDsCSV string) ([]string, []uint32) {
	if recipesCSV == "" {
		panic("recipes is required")
	}
	if itemIDsCSV == "" {
		panic("item ids is required")
	}

	canonicalRecipes := []string{}
	itemIDs := []uint32{}
	recipeStart, recipeEnd := 0, 0
	itemIDStart, itemIDEnd := 0, 0
	for {
		for recipeEnd < len(recipesCSV) && recipesCSV[recipeEnd] != ',' {
			recipeEnd++
		}
		for itemIDEnd < len(itemIDsCSV) && itemIDsCSV[itemIDEnd] != ',' {
			itemIDEnd++
		}

		recipeToken := recipesCSV[recipeStart:recipeEnd]
		itemIDText := itemIDsCSV[itemIDStart:itemIDEnd]
		if recipeToken == "" {
			panic("empty recipe not allowed")
		}
		if itemIDText == "" {
			panic("empty item id not allowed")
		}

		canonicalRecipe, _ := mustParseRecipe(recipeToken)
		itemIDValue, err := strconv.ParseUint(itemIDText, 10, 32)
		if err != nil {
			panic("invalid item id: " + itemIDText)
		}

		canonicalRecipes = append(canonicalRecipes, canonicalRecipe)
		itemIDs = append(itemIDs, uint32(itemIDValue))
		if len(canonicalRecipes) > recipeBatchLimit {
			panic("recipes exceeds 100")
		}

		recipeDone := recipeEnd >= len(recipesCSV)
		itemIDDone := itemIDEnd >= len(itemIDsCSV)
		if recipeDone != itemIDDone {
			panic("recipes and item ids count mismatch")
		}
		if recipeDone {
			return canonicalRecipes, itemIDs
		}

		recipeEnd++
		itemIDEnd++
		recipeStart = recipeEnd
		itemIDStart = itemIDEnd
	}
}

func mustParseRecipeKeyCSV(recipesCSV string) []string {
	if recipesCSV == "" {
		panic("recipes is required")
	}

	canonicalRecipes := []string{}
	recipeStart, recipeEnd := 0, 0
	for {
		for recipeEnd < len(recipesCSV) && recipesCSV[recipeEnd] != ',' {
			recipeEnd++
		}

		recipeToken := recipesCSV[recipeStart:recipeEnd]
		if recipeToken == "" {
			panic("empty recipe not allowed")
		}

		canonicalRecipe, _ := mustParseRecipe(recipeToken)
		canonicalRecipes = append(canonicalRecipes, canonicalRecipe)
		if len(canonicalRecipes) > recipeBatchLimit {
			panic("recipes exceeds 100")
		}

		if recipeEnd >= len(recipesCSV) {
			return canonicalRecipes
		}

		recipeEnd++
		recipeStart = recipeEnd
	}
}

func mustParseRecipe(recipe string) (string, []craftIngredient) {
	canonical, ingredients, errMsg := parseRecipe(recipe)
	if errMsg != "" {
		panic(errMsg)
	}
	return canonical, ingredients
}

// A valid recipe is "<4-hex occupancy>|<ingredient>|...". Occupancy bits
// choose slots 0-15 in order; each ingredient is "tokenId:amount" or
// "slot:tokenId:amount". Example: "0013|iron:1|iron:2|stick:2" (bits 0,1,4)
// canonicalizes to "0013|0:iron:1|1:iron:2|4:stick:2".
func parseRecipe(recipe string) (string, []craftIngredient, string) {
	if len(recipe) < 7 || recipe[4] != '|' {
		return "", nil, "invalid recipe"
	}

	occupancyValue, err := strconv.ParseUint(recipe[:4], 16, 16)
	if err != nil || occupancyValue == 0 {
		return "", nil, "invalid recipe occupancy"
	}
	occupancy := uint16(occupancyValue)
	slots := occupiedSlots(occupancy)

	ingredients := []craftIngredient{}
	entryStart, entryEnd := 5, 5
	for {
		for entryEnd < len(recipe) && recipe[entryEnd] != '|' {
			entryEnd++
		}

		if len(ingredients) == len(slots) {
			return "", nil, "occupied slots and ingredients count mismatch"
		}

		ingredient, errMsg := parseRecipeIngredient(
			recipe[entryStart:entryEnd],
			slots[len(ingredients)],
		)
		if errMsg != "" {
			return "", nil, errMsg
		}
		ingredients = append(ingredients, ingredient)
		if len(ingredients) > maxRecipeIngredients {
			return "", nil, "recipe ingredients exceeds 16"
		}

		if entryEnd >= len(recipe) {
			break
		}

		entryEnd++
		entryStart = entryEnd
	}

	if len(ingredients) != len(slots) {
		return "", nil, "occupied slots and ingredients count mismatch"
	}

	canonicalRecipe := formatOccupancy(occupancy)
	for _, ingredient := range ingredients {
		canonicalRecipe += "|" +
			strconv.FormatUint(uint64(ingredient.Slot), 10) + ":" +
			url.PathEscape(ingredient.TokenID) + ":" +
			strconv.FormatInt(ingredient.Amount, 10)
	}
	return canonicalRecipe, ingredients, ""
}

func parseRecipeIngredient(entry string, expectedSlot uint) (craftIngredient, string) {
	amountSeparator := len(entry) - 1
	for amountSeparator > 0 && entry[amountSeparator] != ':' {
		amountSeparator--
	}
	if amountSeparator == 0 || entry[amountSeparator] != ':' {
		return craftIngredient{}, "invalid recipe ingredient"
	}

	tokenField := entry[:amountSeparator]
	amountText := entry[amountSeparator+1:]
	encodedTokenID := tokenField
	slotPrefixEnd := 0
	for slotPrefixEnd < len(tokenField) && tokenField[slotPrefixEnd] != ':' {
		slotPrefixEnd++
	}
	if slotPrefixEnd < len(tokenField) && tokenField[slotPrefixEnd] == ':' {
		slotValue, err := strconv.ParseUint(tokenField[:slotPrefixEnd], 10, 8)
		if err == nil {
			if uint(slotValue) != expectedSlot {
				return craftIngredient{}, "ingredient slot mismatch"
			}
			encodedTokenID = tokenField[slotPrefixEnd+1:]
		}
	}

	tokenID, err := url.PathUnescape(encodedTokenID)
	if err != nil || tokenID == "" {
		return craftIngredient{}, "invalid item token id"
	}

	amount, err := strconv.ParseInt(amountText, 10, 64)
	if err != nil {
		return craftIngredient{}, "invalid ingredient amount: " + amountText
	}
	if amount <= 0 {
		return craftIngredient{}, "ingredient amount must be positive"
	}

	return craftIngredient{
		Slot:    expectedSlot,
		TokenID: tokenID,
		Amount:  amount,
	}, ""
}

func occupiedSlots(occupancy uint16) []uint {
	slots := []uint{}
	for slot := uint(0); slot < 16; slot++ {
		if occupancy&(uint16(1)<<slot) != 0 {
			slots = append(slots, slot)
		}
	}
	return slots
}

func formatOccupancy(occupancy uint16) string {
	value := strconv.FormatUint(uint64(occupancy), 16)
	return "0000"[:4-len(value)] + value
}

func assertRecipeListPageCount(page, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > listLimit {
		panic("count exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}
