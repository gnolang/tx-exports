package user

import (
	"chain"
	"net/url"
	"strconv"
	"time"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const (
	CreateUserEvent = "CreateUser"
	UpdateUserEvent = "UpdateUser"
	DeleteUserEvent = "DeleteUser"

	createdAtKey = "created_at"
)

// users is address string -> map[string]string.
// The zero value is an empty BPTree with fanout 32.
var users bptree.BPTree

func HasUser(addr address) bool {
	assertIsValidAddress(addr)
	return users.Has(addr.String())
}

func CreateUser(cur realm) {
	addr := accesscontrol.MustGetUserCaller(0, cur)
	if isFrozen {
		panic("user self-service is frozen")
	}
	addrStr := addr.String()
	if users.Has(addrStr) {
		panic("user already exists: " + addrStr)
	}
	users.Set(addrStr, map[string]string{
		createdAtKey: strconv.FormatInt(time.Now().Unix(), 10),
	})
	chain.Emit(CreateUserEvent, "address", addrStr)
}

// AdminCreateUser is idempotent so an operator can safely retry registration.
func AdminCreateUser(cur realm, addr address) {
	accesscontrol.AssertIsAdminOrOperator(0, cur, admin.IsAdmin, admin.IsOperator)
	assertIsValidAddress(addr)
	addrStr := addr.String()
	if users.Has(addrStr) {
		return
	}
	users.Set(addrStr, map[string]string{
		createdAtKey: strconv.FormatInt(time.Now().Unix(), 10),
	})
	chain.Emit(CreateUserEvent, "address", addrStr)
}

func DeleteUser(cur realm) {
	addr := accesscontrol.MustGetUserCaller(0, cur)
	if isFrozen {
		panic("user self-service is frozen")
	}
	deleteUser(addr)
}

func AdminDeleteUser(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertIsValidAddress(addr)
	deleteUser(addr)
}

// DeleteAll removes registrations while preserving freeze and list settings.
func DeleteAll(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	users = bptree.BPTree{}
}

func AdminUpdateUser(cur realm, addr address, propKeys, propValues string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertIsValidAddress(addr)
	addrStr := addr.String()
	current := users.Get(addrStr)
	if current == nil {
		panic("user not found: " + addrStr)
	}
	props := copyStringMap(current.(map[string]string))
	updates := parsePropertiesCSV(propKeys, propValues)
	for key, value := range updates {
		props[key] = value
	}
	users.Set(addrStr, props)
	chain.Emit(UpdateUserEvent, "address", addrStr)
}

func GetTotalUserSize() int {
	return users.Size()
}

func ListUsers(page, count int) []string {
	assertListPageCount(page, count)
	result := []string{}
	offset := (page - 1) * count
	users.IterateByOffset(offset, count, func(key string, _ any) bool {
		result = append(result, key)
		return false
	})
	return result
}

func ListUsersByAddresses(addrs ...address) []map[string]string {
	assertListLimit("addrs", len(addrs))
	result := []map[string]string{}
	for _, addr := range addrs {
		assertIsValidAddress(addr)
		addrStr := addr.String()
		current := users.Get(addrStr)
		if current == nil {
			continue
		}
		props := copyStringMap(current.(map[string]string))
		props["address"] = addrStr
		result = append(result, props)
	}
	return result
}

func deleteUser(addr address) {
	addrStr := addr.String()
	if _, removed := users.Remove(addrStr); !removed {
		panic("user not found: " + addrStr)
	}
	chain.Emit(DeleteUserEvent, "address", addrStr)
}

func copyStringMap(source map[string]string) map[string]string {
	result := map[string]string{}
	for key, value := range source {
		result[key] = value
	}
	return result
}

// parsePropertiesCSV accepts comma-separated keys and comma-separated values.
// Each value must be URL-encoded so commas and other separators can be carried
// safely; this parser URL-decodes values before returning the map.
func parsePropertiesCSV(keys, values string) map[string]string {
	if keys == "" {
		panic("properties keys must be not empty")
	}

	result := map[string]string{}
	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	for {
		for keyIdx < len(keys) && keys[keyIdx] != ',' {
			keyIdx++
		}
		for valIdx < len(values) && values[valIdx] != ',' {
			valIdx++
		}

		key := keys[keyStart:keyIdx]
		if key == "" {
			panic("properties key must be not empty")
		}
		if _, found := result[key]; found {
			panic("properties key duplicated: " + key)
		}

		value, err := url.PathUnescape(values[valStart:valIdx])
		if err != nil {
			panic("properties value URL decode failed: " + key)
		}
		result[key] = value

		keyEnd := keyIdx >= len(keys)
		valEnd := valIdx >= len(values)
		if keyEnd != valEnd {
			panic("properties keys and values count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}

	return result
}

func assertIsValidAddress(addr address) {
	if !addr.IsValid() {
		panic("invalid address: " + addr.String())
	}
}

func assertListLimit(field string, count int) {
	if count > listLimit {
		panic(field + " exceeds listLimit (max: " + strconv.Itoa(listLimit) + ")")
	}
}

func assertListPageCount(page int, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	assertListLimit("count", count)
}
