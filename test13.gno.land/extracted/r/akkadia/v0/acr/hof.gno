package acr

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

const (
	CreateHofCategoryEvent = "CreateHofCategory"
	RemoveHofCategoryEvent = "RemoveHofCategory"
	SetHofEntriesEvent     = "SetHofEntries"
)

// ==================== Admin or Operator Functions ====================

// CreateHofCategory creates a new Hall of Fame category
func CreateHofCategory(cur realm, name string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	validateHofCategoryName(name)
	acrStore.CreateHofCategory(name)

	chain.Emit(
		CreateHofCategoryEvent,
		"caller", caller.String(),
		"name", name,
	)
}

// RemoveHofCategory removes a Hall of Fame category and all its entries
func RemoveHofCategory(cur realm, name string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	acrStore.RemoveHofCategory(name)

	chain.Emit(
		RemoveHofCategoryEvent,
		"caller", caller.String(),
		"name", name,
	)
}

// SetHofEntries sets the entire CSV data for a Hall of Fame category (header included)
func SetHofEntries(cur realm, category string, csvRows string) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	validatedRows := validateHofEntries(csvRows)
	acrStore.SetHofEntries(category, validatedRows)

	chain.Emit(
		SetHofEntriesEvent,
		"caller", caller.String(),
		"category", category,
	)
}

// ==================== Query Functions ====================

// ListHofCategories returns paginated Hall of Fame category names
func ListHofCategories(page int, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return acrStore.ListHofCategories(page, count)
}

func GetHofCategorySize() int {
	assertMigrationStateAvailable()
	return acrStore.HofCategoryCount()
}

// GetHofEntries returns the CSV string for a Hall of Fame category
func GetHofEntries(category string) string {
	assertMigrationStateAvailable()
	return acrStore.GetHofEntries(category)
}
