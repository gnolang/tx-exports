// Package nftprofiles4 lets any address set a lightweight, self-service
// profile (display name + avatar URI) shown across the gnoNFT frontend
// wherever an address would otherwise render as a raw g1... string with a
// generated initials avatar.
//
// WHAT CHANGED VS V1 (gno.land/r/g1hx4z2.../nftprofiles)
//
//  1. SetProfile no longer trusts unsafe.OriginCaller(). In v1 any realm
//     the user called could rewrite that user's display name and avatar
//     behind their back — low severity, but it is impersonation surface
//     on a field the UI shows next to real listings and sales, so it is
//     worth closing. Authorization is cur.Previous().Address() now.
//
//  2. Display names are unique and normalised. v1 let a thousand
//     addresses all call themselves "hazen", which makes a display name
//     actively misleading in a marketplace context. v2 keeps a lowercase
//     name index and rejects a name already taken by another address.
//
//  3. ResolveName lets the UI go from a name back to an address, and
//     ProfileCount/ListProfiles make the set browsable.
//
// Cosmetic only: no other realm's authorization logic keys off anything
// here. Ownership and creator checks everywhere else use raw addresses.
package nftprofiles4

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// MaxDisplayNameLen and MaxAvatarURILen keep storage bounded and prevent
// this from being used as generic blob storage.
const (
	MaxDisplayNameLen = 32
	MinDisplayNameLen = 2
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

var (
	profiles  = avl.NewTree() // address.String() -> *Profile
	nameIndex = avl.NewTree() // lowercased displayName -> address.String()
	profCount int64
)

// SetProfile sets or updates the caller's own display name and avatar
// URI. Passing both empty removes the profile entirely (and frees the
// name for someone else).
func SetProfile(cur realm, displayName, avatarURI string) {
	caller := cur.Previous().Address()
	key := caller.String()

	if len(displayName) > MaxDisplayNameLen {
		panic("display name too long (max " + strconv.Itoa(MaxDisplayNameLen) + " chars)")
	}
	if len(avatarURI) > MaxAvatarURILen {
		panic("avatar URI too long (max " + strconv.Itoa(MaxAvatarURILen) + " chars)")
	}

	displayName = strings.TrimSpace(displayName)
	if displayName != "" && len(displayName) < MinDisplayNameLen {
		panic("display name too short (min " + strconv.Itoa(MinDisplayNameLen) + " chars)")
	}
	assertSafeDisplayName(displayName)
	assertSafeAvatarURI(avatarURI)

	prev, hadProfile := avlGet(profiles, key).(*Profile)

	if displayName == "" && avatarURI == "" {
		if hadProfile {
			releaseName(prev.displayName)
			profiles.Remove(key)
			if profCount > 0 {
				profCount--
			}
			chain.Emit("ProfileCleared", "address", key)
		}
		return
	}

	if displayName != "" {
		lower := strings.ToLower(displayName)
		if owner, taken := avlGet(nameIndex, lower).(string); taken && owner != key {
			panic("display name \"" + displayName + "\" is already taken")
		}
		if hadProfile {
			releaseName(prev.displayName)
		}
		nameIndex.Set(lower, key)
	} else if hadProfile {
		releaseName(prev.displayName)
	}

	if !hadProfile {
		profCount++
	}
	profiles.Set(key, &Profile{
		address:     caller,
		displayName: displayName,
		avatarURI:   avatarURI,
		updatedAt:   runtime.ChainHeight(),
	})

	chain.Emit("ProfileUpdated", "address", key, "displayName", displayName)
}

// GetProfile returns the profile for an address, or a zero-value
// ProfileInfo if none was set — callers treat that as "use the generated
// fallback avatar".
func GetProfile(addr address) ProfileInfo {
	v := avlGet(profiles, addr.String())
	if v == nil {
		return ProfileInfo{Address: addr}
	}
	return toInfo(v.(*Profile))
}

// ResolveName returns the address that owns a display name, or an empty
// address if the name is unclaimed. Case-insensitive.
func ResolveName(displayName string) address {
	v := avlGet(nameIndex, strings.ToLower(strings.TrimSpace(displayName)))
	if v == nil {
		return ""
	}
	return address(v.(string))
}

// ListProfiles returns a page of profiles, ordered by address.
func ListProfiles(offset, limit int64) []ProfileInfo {
	out := make([]ProfileInfo, 0, limit)
	profiles.IterateByOffset(int(offset), int(limit), func(key string, value any) bool {
		out = append(out, toInfo(value.(*Profile)))
		return false
	})
	return out
}

// ProfileCount returns how many addresses currently have a profile.
func ProfileCount() int64 { return profCount }

// Render implements the gno.land realm home-page convention. Path, if
// given, is the bech32 address to look up.
func Render(path string) string {
	if path != "" {
		info := GetProfile(address(path))
		if info.DisplayName == "" && info.AvatarURI == "" {
			return "# " + path + "\n\nno profile set.\n"
		}
		return "# " + path + "\n\n- Display name: " + info.DisplayName +
			"\n- Avatar: " + info.AvatarURI + "\n"
	}

	out := "# gnoNFT Profiles v2\n\n"
	if profCount == 0 {
		return out + "No profiles set yet.\n"
	}
	profiles.Iterate("", "", func(key string, value any) bool {
		p := value.(*Profile)
		out += "- " + key + ": " + p.displayName + "\n"
		return false
	})
	return out
}

// assertSafeDisplayName restricts a display name to a printable ASCII
// subset. Without it a name can carry markdown, angle brackets, control
// characters or Unicode look-alikes (Cyrillic "а" for Latin "a") and
// impersonate another seller in the UI, where the name is shown right
// next to real listings and sales. The uniqueness index only protects
// against exact duplicates, so the character set has to do the rest.
func assertSafeDisplayName(name string) {
	if name == "" {
		return
	}
	for i := 0; i < len(name); i++ {
		ch := name[i]
		ok := (ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == ' ' || ch == '_' || ch == '-' || ch == '.'
		if !ok {
			panic("display name may only contain letters, digits, space, '_', '-' and '.'")
		}
	}
	if strings.HasPrefix(strings.ToLower(name), "g1") {
		panic("display name must not look like a bech32 address")
	}
}

// assertSafeAvatarURI allows only schemes a client can render without
// executing anything. An avatar URI is put straight into an <img>/<a> by
// the frontend, so "javascript:" and "data:text/html" belong nowhere
// near it - and a realm must not rely on every client sanitising it.
func assertSafeAvatarURI(uri string) {
	if uri == "" {
		return
	}
	lower := strings.ToLower(uri)
	if strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "ipfs://") ||
		strings.HasPrefix(lower, "ar://") ||
		strings.HasPrefix(lower, "data:image/") {
		return
	}
	panic("avatar URI must start with https://, ipfs://, ar:// or data:image/")
}

func releaseName(displayName string) {
	if displayName != "" {
		nameIndex.Remove(strings.ToLower(displayName))
	}
}

func toInfo(p *Profile) ProfileInfo {
	return ProfileInfo{
		Address:     p.address,
		DisplayName: p.displayName,
		AvatarURI:   p.avatarURI,
		UpdatedAt:   p.updatedAt,
	}
}
