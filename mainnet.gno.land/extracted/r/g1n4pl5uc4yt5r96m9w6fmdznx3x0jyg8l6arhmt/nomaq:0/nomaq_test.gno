package nomaq

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
)

const perk2 = "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/perk2"

func resetAll() {
	bySlug = avl.Tree{}
	byPkg = avl.Tree{}
	reserved = avl.Tree{}
	holderDisc = avl.Tree{}
	inited = false
	launchFee = 0
	protocolBps = 0
	genesisPkg = ""
	genesisShareBps = 0
	discountPusher = ""
	var zero address
	admin = zero
	self = zero
	protocolSink = zero
	genesisSink = zero
}

func TestGenesisShareDefault(cur realm, t *testing.T) {
	resetAll()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	Init(cross(cur))
	if GenesisShareBps() != 0 {
		t.Fatalf("share before genesis %d", GenesisShareBps())
	}
	if ProtocolBps() != defaultProtocolBps {
		t.Fatalf("protocol %d", ProtocolBps())
	}
	SetGenesis(cross(cur), perk2)
	if GenesisPkg() != perk2 {
		t.Fatalf("pkg %q", GenesisPkg())
	}
	if GenesisSink() != chain.PackageAddress(perk2) {
		t.Fatalf("sink %s", GenesisSink())
	}
	if GenesisShareBps() != defaultGenesisShareBps {
		t.Fatalf("share %d", GenesisShareBps())
	}
	if GenesisShareBps() == 1100 {
		t.Fatalf("v5 fallback must not apply")
	}
	if !strings.Contains(Render(""), "holder share: 2500 bps") {
		t.Fatalf("render %q", Render(""))
	}
}

func TestSetGenesisShareBps(cur realm, t *testing.T) {
	resetAll()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	Init(cross(cur))
	SetGenesisShareBps(cross(cur), 3000)
	if GenesisShareBps() != 0 {
		t.Fatalf("share before genesis %d", GenesisShareBps())
	}
	SetGenesis(cross(cur), perk2)
	if GenesisShareBps() != 3000 {
		t.Fatalf("kept setter %d", GenesisShareBps())
	}
	SetGenesisShareBps(cross(cur), 0)
	if GenesisShareBps() != 0 {
		t.Fatalf("zero share %d", GenesisShareBps())
	}
	SetGenesisShareBps(cross(cur), maxGenesisShareBps)
	if GenesisShareBps() != 10000 {
		t.Fatalf("full share %d", GenesisShareBps())
	}
	SetGenesisShareBps(cross(cur), 2500)
	if GenesisShareBps() != 2500 {
		t.Fatalf("restore %d", GenesisShareBps())
	}
}

func TestSetGenesisDoesNotResetShare(cur realm, t *testing.T) {
	resetAll()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	Init(cross(cur))
	SetGenesisShareBps(cross(cur), 0)
	SetGenesis(cross(cur), perk2)
	if GenesisShareBps() != 0 {
		t.Fatalf("set genesis clobbered zero %d", GenesisShareBps())
	}
	SetGenesis(cross(cur), perk2)
	if GenesisShareBps() != 0 {
		t.Fatalf("second set genesis %d", GenesisShareBps())
	}
}

func TestSetGenesisShareRejected(cur realm, t *testing.T) {
	resetAll()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	testing.SetRealm(testing.NewUserRealm(alice))
	Init(cross(cur))
	SetGenesis(cross(cur), perk2)

	got := revive(func() { SetGenesisShareBps(cross(cur), -1) })
	if got == nil {
		t.Fatalf("expected negative reject")
	}
	got = revive(func() { SetGenesisShareBps(cross(cur), maxGenesisShareBps+1) })
	if got == nil {
		t.Fatalf("expected above max reject")
	}
	if GenesisShareBps() != defaultGenesisShareBps {
		t.Fatalf("rejected call changed share %d", GenesisShareBps())
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	got = revive(func() { SetGenesisShareBps(cross(cur), 2500) })
	if got == nil {
		t.Fatalf("expected not admin")
	}

	testing.SetRealm(testing.NewCodeRealm(perk2))
	got = revive(func() { SetGenesisShareBps(cross(cur), 2500) })
	if got == nil {
		t.Fatalf("expected EOA only")
	}
	if GenesisShareBps() != defaultGenesisShareBps {
		t.Fatalf("rejected caller changed share %d", GenesisShareBps())
	}
}

func TestAttachGenesisKeepsShare(cur realm, t *testing.T) {
	resetAll()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	Init(cross(cur))
	SetGenesis(cross(cur), perk2)
	testing.SetRealm(testing.NewUserRealm(alice))
	got := revive(func() { AttachGenesis(cross(cur)) })
	if got == nil {
		t.Fatalf("expected genesis realm")
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/other"))
	got = revive(func() { AttachGenesis(cross(cur)) })
	if got == nil {
		t.Fatalf("expected not admin")
	}
	if GenesisPkg() != perk2 {
		t.Fatalf("pkg changed %q", GenesisPkg())
	}
	if GenesisShareBps() != defaultGenesisShareBps {
		t.Fatalf("share changed %d", GenesisShareBps())
	}
}
