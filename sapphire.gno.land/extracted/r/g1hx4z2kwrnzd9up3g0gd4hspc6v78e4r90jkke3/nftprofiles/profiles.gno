// Package nftprofiles lets any address set a lightweight, self-service
// profile (display name + avatar image URI) shown across the gnoNFT
// frontend wherever that address would otherwise just be a raw
// g1... string with a generated color+initials avatar
// (components/Avatar.tsx). Separate realm rather than bolting onto
// nft.gno/nftmarket.gno/nftoffers.gno/nftlimits.gno for the same
// immutability reason all of those already are: each is independently
// deployed and none of them has any notion of "user profile".
//
// Fully self-service and permissionless: anyone can set their own
// profile for their own address (unsafe.OriginCaller()), there's no
// registration/approval step. Cosmetic only — this has no bearing on
// any other realm's authorization logic (ownership/creator checks
// everywhere else still key off the raw address, never off this
// display name).
package nftprofiles

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// MaxDisplayNameLen and MaxAvatarURILen keep storage costs bounded and
// prevent this from being used as generic blob storage.
const (
	MaxDisplayNameLen = 32
	MaxAvatarURILen   = 256
)

// Profile is one address's self-set profile.
type Profile struct {
	address     address
	displayName string
	avatarURI   string
	updatedAt   int64
}

// ProfileInfo is the exported, read-only view of a Profile.
type ProfileInfo struct {
	Address     address
	DisplayName string
	AvatarURI   string
	UpdatedAt   int64
}

var profiles = avl.NewTree() // address.String() -> *Profile

// SetProfile sets (or updates) the caller's own display name and/or
// avatar URI. Pass an empty string for either field to clear just that
// field while keeping the other. Calling with both empty removes the
// profile entirely (reverting the address to the frontend's generated
// fallback avatar).
func SetProfile(cur realm, displayName, avatarURI string) {
	caller := unsafe.OriginCaller()

	if len(displayName) > MaxDisplayNameLen {
		panic("display name too long (max " + strconv.Itoa(MaxDisplayNameLen) + " chars)")
	}
	if len(avatarURI) > MaxAvatarURILen {
		panic("avatar URI too long (max " + strconv.Itoa(MaxAvatarURILen) + " chars)")
	}

	key := caller.String()
	if displayName == "" && avatarURI == "" {
		profiles.Remove(key)
		return
	}

	profiles.Set(key, &Profile{
		address:     caller,
		displayName: displayName,
		avatarURI:   avatarURI,
		updatedAt:   runtime.ChainHeight(),
	})
}

// GetProfile returns the profile for an address, or a zero-value
// ProfileInfo (empty DisplayName/AvatarURI, UpdatedAt == 0) if none was
// ever set — callers should treat that as "use the generated fallback".
func GetProfile(addr address) ProfileInfo {
	v := profiles.Get(addr.String())
	if v == nil {
		return ProfileInfo{Address: addr}
	}
	return toInfo(v.(*Profile))
}

// Render implements the gno.land realm home-page convention. Path, if
// given, is the bech32 address to look up (mirrors the other realms'
// single-path-segment convention).
func Render(path string) string {
	if path != "" {
		info := GetProfile(address(path))
		if info.DisplayName == "" && info.AvatarURI == "" {
			return "# " + path + "\n\nno profile set.\n"
		}
		return "# " + path + "\n\n- Display name: " + info.DisplayName + "\n- Avatar: " + info.AvatarURI + "\n"
	}

	out := "# Hazen NFT Profiles\n\n"
	hasAny := false
	profiles.Iterate("", "", func(key string, value any) bool {
		hasAny = true
		p := value.(*Profile)
		out += "- " + key + ": " + p.displayName + "\n"
		return false
	})
	if !hasAny {
		out += "No profiles set yet.\n"
	}
	return out
}

func toInfo(p *Profile) ProfileInfo {
	return ProfileInfo{
		Address:     p.address,
		DisplayName: p.displayName,
		AvatarURI:   p.avatarURI,
		UpdatedAt:   p.updatedAt,
	}
}
