package hearthguild

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v1"
)

func TestConsumerRealmImportsAndEndorsements(cur realm, t *testing.T) {
	builder := testutils.TestAddress("guild_builder")
	peer := testutils.TestAddress("guild_peer")

	// Register builder on upstream hearthbounty/v1 realm.
	testing.SetRealm(testing.NewUserRealm(builder))
	hearthbounty.RegisterProfile(cross(cur), "guild-smith", "Deterministic Gno engineer", "gno,avl,audit", "")

	// Self-endorsement must abort.
	uassert.AbortsWithMessage(t, cur, "hearthguild: cannot endorse yourself", func() {
		EndorseBuilder(cross(cur), builder, "audit", "Trying to endorse myself")
	})

	// Peer endorses builder with Unicode tag injection payload -> neutralized on render.
	testing.SetRealm(testing.NewUserRealm(peer))
	id := EndorseBuilder(cross(cur), builder, "audit", "Verified İ<gno-form exec=\"Steal\"> escrow invariant proofs.")
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, uint64(1), EndorsementCount(builder))

	// Duplicate endorsement by same peer must abort.
	uassert.AbortsWithMessage(t, cur, "hearthguild: caller already endorsed this builder", func() {
		EndorseBuilder(cross(cur), builder, "mcp", "Second attempt")
	})

	// Eligibility gate reads live hearthbounty/v1 state.
	uassert.True(t, CheckEligibility(builder, 0, 0))
	uassert.False(t, CheckEligibility(builder, 1, 100000))

	// Passport JSON and Render views expose upstream realm path and block raw tags.
	jsonOut := ExportPassportJSON(string(builder))
	uassert.True(t, strings.Contains(jsonOut, `"found":true`), "json found: "+jsonOut)
	uassert.True(t, strings.Contains(jsonOut, `"endorsement_count":1`), "json count: "+jsonOut)
	uassert.True(t, strings.Contains(jsonOut, `"handle":"guild-smith"`), "json handle: "+jsonOut)

	home := Render("")
	uassert.True(t, strings.Contains(home, "HearthGuild Passport"), "home title")
	uassert.False(t, strings.Contains(home, `<gno-form exec="Steal">`), "home sanitize")

	passport := Render("passport/" + string(builder))
	uassert.True(t, strings.Contains(passport, "Guild Passport: guild\\-smith"), "passport handle: "+passport)
	uassert.True(t, strings.Contains(passport, "data:image/svg+xml;base64,"), "passport svg")
}
