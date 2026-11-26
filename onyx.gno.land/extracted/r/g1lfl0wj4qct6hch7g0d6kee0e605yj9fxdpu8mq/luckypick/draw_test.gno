package luckypick

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	evmnet "gno.land/p/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0"
)

func TestDraw(cur realm, t *testing.T) {
	// Replay the public evmnet round 1000 with the VM clock just before it.
	const round = uint64(1000)
	const signature = "06fd5996329504d3a56b482d9222bf7205857d0a9559ddd216ca31a286f6a8cc0a120f021aac2f13553fb164f62bc3a5ca32c76dea88a777b39bcf3cac5fdbd6"
	ctx := testing.GetContext()
	ctx.Time = time.Unix(evmnet.TimeOf(round)-lookaheadSeconds-1, 0)
	testing.SetContext(ctx)
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("player")))
	uassert.AbortsWithMessage(t, cur, "pick a number from 1 to 4", func() { Pick(cross(cur), 5) })
	id := Pick(cross(cur), 3)
	r, picked, drawn := Receipt(id)
	uassert.Equal(t, round, r)
	uassert.Equal(t, 3, picked)
	uassert.Equal(t, 0, drawn)
	uassert.True(t, strings.Contains(Render(""), id))
	uassert.AbortsWithMessage(t, cur, "randomness not available yet", func() { Settle(cross(cur), id) })

	testing.SkipHeights(15)
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("relay")))
	uassert.AbortsWithMessage(t, cur, "invalid drand signature", func() { drand.Submit(cross(cur), round, strings.Repeat("00", 64)) })
	drand.Submit(cross(cur), round, signature)
	uassert.True(t, strings.Contains(Render(id), "Ready to settle"))

	// Recompute directly from the signature, independently of the realm's Get.
	sig, _ := hex.DecodeString(signature)
	beacon := sha256.Sum256(sig)
	salt := chain.PackageAddress("gno.land/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick").String() + ":" + id
	expected := sha256.Sum256(append(beacon[:], []byte(salt)...))
	want := 1 + int(expected[0]%4)
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("observer")))
	uassert.Equal(t, want, Settle(cross(cur), id))
	uassert.Equal(t, want, Settle(cross(cur), id))
	_, _, result := Receipt(id)
	uassert.Equal(t, want, result)
	uassert.True(t, strings.Contains(Render(id), "Drawn:"))
	t.Logf("evmnet round %d, request %s, picked 3, verified result %d", round, id, result)
}
