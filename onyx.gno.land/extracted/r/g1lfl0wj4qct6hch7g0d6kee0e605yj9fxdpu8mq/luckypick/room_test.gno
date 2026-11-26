package luckypick

import (
	"chain"
	"chain/banker"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	evmnet "gno.land/p/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/drand/v0"
)

var gameAddr = chain.PackageAddress("gno.land/r/g1lfl0wj4qct6hch7g0d6kee0e605yj9fxdpu8mq/luckypick")

// MsgCall credits the realm before invoking its function. The Gno unit-test
// runner calls the function directly, so reproduce that keeper credit here.
func creditEnvelope(amount int64) {
	coins := chain.Coins{{"ugnot", amount}}
	testing.SetOriginSend(coins)
	testing.IssueCoins(gameAddr, coins)
}

func balance(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

func TestRoomPayouts(cur realm, t *testing.T) {
	host := testutils.TestAddress("roomhost")
	player := testutils.TestAddress("roomplayer")
	initial := balance(gameAddr)
	hostStart, playerStart := balance(host), balance(player)
	// Each pick uses a different real drand round. Predict its output from the
	// archived signature only in this replay, to exercise both payout branches.
	fixtures := []struct {
		round uint64
		sig   string
	}{
		{1, "11f812d738a36b2210dc88c2d635ad8039588205f42445d6de09e6530165c3462a23aca348c84badcf8df5321ac24577b7963d5b0d780bc4626baedb45cde373"},
		{2, "1dbfe644485f31e2a7978fb551b50933b0001e64397fd2b7dc4022e8e2fcdbc325798cea5506deec489c8db3b4697f6b1bb6be8934b95bd9c0db88923487d9ad"},
		{1000000, "139a803860ff6d842b822b8b37eaeccc4e278dd44440535a976530a1a503e85e11d84b824f18e608a85e627e6b1b08322060cbcf7eca1ea78489252907e8473a"},
		{10000000, "2c7b65b5acfe55256910ca71cf0a0fa71ac34c2a1167f86a22930a03e70ebec00f7a530796e7ee38600b06da0390634a9b154e3eebc3b323dde2111e1c8ebdf3"},
		{20000000, "1ad7a10ece71f082a5c931983eca674ecb297b22f9396cde3a5015b9d91795411f11d5de506f74f17645ac04a2fe6b53458a123f66e2fcb1e2ab86cb8c2d5409"},
		{21167346, "05ac314484cc91d6a4fdac301d34949526af8ca11ccd3f028357b9596a07ee8504c39404fbd9e4d730a700c144aa05bf0a0963b897fb2e9ea9be9bd47382e9b2"},
	}
	testing.SetRealm(testing.NewUserRealm(host))
	creditEnvelope(prize)
	winRoom := OpenRoom(cross(cur))
	testing.SetRealm(testing.NewUserRealm(host))
	creditEnvelope(prize)
	missRoom := OpenRoom(cross(cur))
	testing.SetRealm(testing.NewUserRealm(host))
	creditEnvelope(prize)
	idleRoom := OpenRoom(cross(cur))

	for i, f := range fixtures {
		ctx := testing.GetContext()
		ctx.Time = time.Unix(evmnet.TimeOf(f.round)-lookaheadSeconds-1, 0)
		testing.SetContext(ctx)
		testing.SetRealm(testing.NewUserRealm(player))
		probeID := drand.Request(cross(cur))
		next, err := seqid.FromString(probeID)
		if err != nil {
			t.Fatal(err)
		}
		predictedID := next.Next().String()
		sig, _ := hex.DecodeString(f.sig)
		beacon := sha256.Sum256(sig)
		hash := sha256.Sum256(append(beacon[:], []byte(gameAddr.String()+":"+predictedID)...))
		drawn := int(hash[0]%4) + 1
		choice := drawn%4 + 1
		id := missRoom
		if i == 0 {
			id = winRoom
			choice = drawn
		}
		testing.SetRealm(testing.NewUserRealm(player))
		creditEnvelope(entry)
		req := JoinRoom(cross(cur), id, choice)
		uassert.Equal(t, predictedID, req)
		uassert.Equal(t, req, getRoom(id).pending)
		uassert.True(t, strings.Contains(PendingPicks(""), req))
		actualRound, _, _ := Receipt(req)
		uassert.Equal(t, f.round, actualRound)
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(host))
		uassert.AbortsWithMessage(t, cur, "room is closed or awaiting settlement", func() { CloseRoom(cross(cur), id) })
		testing.SkipHeights(15)
		drand.Submit(cross(cur), f.round, f.sig)
		uassert.Equal(t, drawn, Settle(cross(cur), req))
		uassert.Equal(t, drawn, Settle(cross(cur), req))
		uassert.Equal(t, "", getRoom(id).pending)
		uassert.False(t, strings.Contains(PendingPicks(""), req))
		if i == 1 { // First settled miss in missRoom.
			ctx := testing.GetContext()
			ctx.Time = time.Unix(ctx.Time.Unix()+48*60*60, 0)
			testing.SetContext(ctx)
			uassert.AbortsWithMessage(t, cur, "only rooms with no guesses can be closed", func() { CloseRoom(cross(cur), id) })
			uassert.False(t, strings.Contains(Render("room/"+id), "func=CloseRoom"))
		}
		wantHost := hostStart + int64(i+1)*entry
		if i == 5 {
			wantHost += prize
		}
		uassert.Equal(t, wantHost, balance(host))
		uassert.Equal(t, playerStart+prize, balance(player))
	}
	uassert.Equal(t, "Player won", getRoom(winRoom).status())
	uassert.Equal(t, "Host won", getRoom(missRoom).status())
	uassert.Equal(t, initial+prize, balance(gameAddr))
	uassert.True(t, strings.Contains(Render("room/"+missRoom), "5/5"))
	uassert.True(t, strings.Contains(Render("room/"+idleRoom), "func=CloseRoom"))
	CloseRoom(cross(cur), idleRoom)
	uassert.AbortsWithMessage(t, cur, "room is closed or awaiting settlement", func() { CloseRoom(cross(cur), idleRoom) })
	uassert.Equal(t, initial, balance(gameAddr))
	uassert.Equal(t, hostStart+6*entry+2*prize, balance(host))
}

func TestRoomGuards(cur realm, t *testing.T) {
	host := testutils.TestAddress("host")
	player := testutils.TestAddress("guest")
	for _, coins := range []chain.Coins{nil, {{"ugnot", entry}}, {{"other", prize}}, {{"other", 1}, {"ugnot", prize}}} {
		testing.SetOriginSend(coins)
		uassert.PanicsWithMessage(t, cur, "send exactly 400000ugnot", func() { requireDeposit(prize) })
	}
	testing.SetRealm(testing.NewUserRealm(host))
	creditEnvelope(prize)
	id := OpenRoom(cross(cur))
	testing.SetRealm(testing.NewUserRealm(player))
	creditEnvelope(entry)
	uassert.AbortsWithMessage(t, cur, "host only", func() { CloseRoom(cross(cur), id) })
	ctx := testing.GetContext()
	ctx.Time = time.Unix(evmnet.TimeOf(32000), 0)
	testing.SetContext(ctx)
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() { JoinRoom(cross(cur), id, 2) })
	req := JoinRoom(cross(cur), id, 1)
	uassert.AbortsWithMessage(t, cur, "room is closed or awaiting settlement", func() { JoinRoom(cross(cur), id, 4) })
	uassert.Equal(t, req, getRoom(id).pending)
	uassert.Equal(t, 1, len(getRoom(id).picks))
}
