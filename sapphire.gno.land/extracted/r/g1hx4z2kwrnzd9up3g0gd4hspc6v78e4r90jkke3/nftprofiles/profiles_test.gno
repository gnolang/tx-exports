package nftprofiles

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestSetAndGetProfile(cur realm, t *testing.T) {
	alice := testutils.TestAddress("prof-alice")

	t.Run("no profile initially", func(t *testing.T) {
		info := GetProfile(alice)
		uassert.Equal(t, "", info.DisplayName)
		uassert.Equal(t, "", info.AvatarURI)
	})

	t.Run("alice sets her profile", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		SetProfile(cross(cur), "Alice", "ipfs://bafy.../avatar.png")

		info := GetProfile(alice)
		uassert.Equal(t, "Alice", info.DisplayName)
		uassert.Equal(t, "ipfs://bafy.../avatar.png", info.AvatarURI)
	})

	t.Run("alice clears her profile", func(t *testing.T) {
		testing.SetOriginCaller(alice)
		SetProfile(cross(cur), "", "")

		info := GetProfile(alice)
		uassert.Equal(t, "", info.DisplayName)
		uassert.Equal(t, "", info.AvatarURI)
	})
}

func TestDisplayNameTooLong(cur realm, t *testing.T) {
	alice := testutils.TestAddress("prof-alice2")
	testing.SetOriginCaller(alice)

	tooLong := strings.Repeat("x", MaxDisplayNameLen+1)
	uassert.AbortsWithMessage(t, cur, "display name too long (max 32 chars)", func() {
		SetProfile(cross(cur), tooLong, "")
	})
}

func TestOnlyAffectsOwnAddress(cur realm, t *testing.T) {
	alice := testutils.TestAddress("prof-alice3")
	bob := testutils.TestAddress("prof-bob3")

	testing.SetOriginCaller(alice)
	SetProfile(cross(cur), "Alice", "")

	uassert.Equal(t, "", GetProfile(bob).DisplayName)
}
