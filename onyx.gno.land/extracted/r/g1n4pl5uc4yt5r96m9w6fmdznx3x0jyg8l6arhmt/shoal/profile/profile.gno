// Package profile is the Shoal sailor card. One address has one username.
// This realm holds no ugnot. It does not mint FISH and it does not mint a fish NFT.
// Deployed on onyx-1 at gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/profile.
// The older profile package at the founder root stays as it was.
package profile

import (
	"chain"
	"chain/runtime/unsafe"
)

type card struct {
	username string
	country  string
	crest    string
}

var (
	byAddr       map[address]*card
	byName       map[string]address
	admin        address
	adminSet     bool
	extraCountry map[string]bool
	extraCrest   map[string]bool
)

// SetProfile stores this caller's sailor card. The caller does not need a fish NFT.
// A later fact is a new function. This one keeps username, country, and crest.
func SetProfile(cur realm, username, country, crest string) {
	caller := requireUser(cur)
	takeExact(0)
	name := cleanUser(username)
	if name == "" {
		panic("profile: name")
	}
	if !knownCountry(country) {
		panic("profile: country")
	}
	if !knownCrest(crest) {
		panic("profile: crest")
	}
	ensure()
	if owner, ok := byName[name]; ok && owner != caller {
		panic("profile: taken")
	}
	prev := byAddr[caller]
	if prev != nil && prev.username == name && prev.country == country && prev.crest == crest {
		return
	}
	if prev != nil && prev.username != name {
		delete(byName, prev.username)
	}
	byAddr[caller] = &card{username: name, country: country, crest: crest}
	byName[name] = caller
	chain.Emit("SetProfile", "who", caller.String(), "username", name, "country", country, "crest", crest)
}

// Version names this local package shape. The live profile realm is unchanged.
func Version() string { return "profile-1" }

// Admin is empty until ClaimAdmin. SetProfile does not claim it.
func Admin() address { return admin }

// ClaimAdmin records the first caller. A later caller cannot replace them here.
func ClaimAdmin(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	if adminSet {
		panic("profile: admin")
	}
	admin = caller
	adminSet = true
	chain.Emit("ClaimAdmin", "who", caller.String())
}

// AddCountry lets the admin accept one more country name. Built-in names stay.
func AddCountry(cur realm, name string) {
	caller := requireUser(cur)
	takeExact(0)
	if !adminSet || caller != admin {
		panic("profile: admin")
	}
	if !placeName(name) || knownCountry(name) {
		panic("profile: country")
	}
	if extraCountry == nil {
		extraCountry = make(map[string]bool)
	}
	extraCountry[name] = true
	chain.Emit("AddCountry", "name", name)
}

// AddCrest lets the admin accept one more crest name. Built-in names stay.
func AddCrest(cur realm, name string) {
	caller := requireUser(cur)
	takeExact(0)
	if !adminSet || caller != admin {
		panic("profile: admin")
	}
	if !placeName(name) || knownCrest(name) {
		panic("profile: crest")
	}
	if extraCrest == nil {
		extraCrest = make(map[string]bool)
	}
	extraCrest[name] = true
	chain.Emit("AddCrest", "name", name)
}

func Has(cur realm, who address) bool {
	takeExact(0)
	return cardOf(who) != nil
}

func UsernameOf(cur realm, who address) string {
	takeExact(0)
	body := cardOf(who)
	if body == nil {
		return ""
	}
	return body.username
}

func CountryOf(cur realm, who address) string {
	takeExact(0)
	body := cardOf(who)
	if body == nil {
		return ""
	}
	return body.country
}

func CrestOf(cur realm, who address) string {
	takeExact(0)
	body := cardOf(who)
	if body == nil {
		return ""
	}
	return body.crest
}

func AddressOf(cur realm, username string) address {
	takeExact(0)
	name := cleanUser(username)
	if name == "" || byName == nil {
		return address("")
	}
	return byName[name]
}

func requireUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("profile: eoa")
	}
	return cur.Previous().Address()
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("profile: payment")
		}
		return
	}
	panic("profile: payment")
}

func ensure() {
	if byAddr == nil {
		byAddr = make(map[address]*card)
	}
	if byName == nil {
		byName = make(map[string]address)
	}
}

func cardOf(who address) *card {
	if byAddr == nil || !who.IsValid() {
		return nil
	}
	return byAddr[who]
}

func cleanUser(name string) string {
	for len(name) > 0 && name[0] == ' ' {
		name = name[1:]
	}
	for len(name) > 0 && name[len(name)-1] == ' ' {
		name = name[:len(name)-1]
	}
	if len(name) < 3 || len(name) > 16 {
		return ""
	}
	out := ""
	for _, c := range name {
		if c >= 'A' && c <= 'Z' {
			c = c - 'A' + 'a'
		}
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return ""
		}
		out += string(c)
	}
	return out
}

func knownCountry(s string) bool {
	switch s {
	case "Sea", "Vietnam", "Korea", "Japan", "Brazil", "France", "Nigeria", "Canada", "Australia":
		return true
	}
	return extraCountry != nil && extraCountry[s]
}

func knownCrest(s string) bool {
	switch s {
	case "wave", "reef", "moon", "sun", "fang", "shell":
		return true
	}
	return extraCrest != nil && extraCrest[s]
}

func placeName(s string) bool {
	if len(s) < 2 || len(s) > 24 {
		return false
	}
	for _, c := range s {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') {
			return false
		}
	}
	return true
}
