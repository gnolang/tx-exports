package dragonhearth

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestHatch(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	testing.SetOriginCaller(alice)
	id := Hatch(cross(cur), "Ember", "Ember")
	d := getDragon(id)
	uassert.Equal(t, int64(1), d.Level)
	uassert.Equal(t, int64(0), d.XP)
	uassert.Equal(t, int64(100), d.Hunger)
	uassert.True(t, d.Soulbound)
	uassert.True(t, d.Power >= 20 && d.Power <= 35)
	uassert.True(t, d.Speed >= 20 && d.Speed <= 35)
	uassert.True(t, d.Vitality >= 20 && d.Vitality <= 35)
	uassert.True(t, d.Trait == "Brave" || d.Trait == "Swift" || d.Trait == "Hardy" || d.Trait == "Stubborn")
	// One starter per wallet.
	urequire.AbortsContains(t, cur, "already hatched", func() {
		Hatch(cross(cur), "Second", "Storm")
	})
}

func TestHatchInvalid(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice2")
	testing.SetOriginCaller(alice)
	urequire.AbortsContains(t, cur, "invalid element", func() {
		Hatch(cross(cur), "Bad", "Water")
	})
	urequire.AbortsContains(t, cur, "invalid name", func() {
		Hatch(cross(cur), "Bad[Name]", "Ember")
	})
}

func TestTrainAndFeed(cur realm, t *testing.T) {
	bob := testutils.TestAddress("bob")
	testing.SetOriginCaller(bob)
	id := Hatch(cross(cur), "Bobo", "Ember")
	before := getDragon(id)
	// Ember's element stat is Power: +10 XP +5 bonus = 15 XP.
	res := Train(cross(cur), id, "Power")
	after := getDragon(id)
	uassert.Equal(t, before.Power+2, after.Power)
	uassert.Equal(t, int64(15), after.XP)
	uassert.Equal(t, int64(90), after.Hunger)
	uassert.True(t, strings.Contains(res, "Trained"))
	// 50-block cooldown: a second train at the same height aborts.
	urequire.AbortsContains(t, cur, "cooldown", func() {
		Train(cross(cur), id, "Speed")
	})
	// Forage then feed: hunger back to 100, food spent.
	food := ClaimFood(cross(cur))
	uassert.Equal(t, int64(1), food)
	Feed(cross(cur), id)
	fed := getDragon(id)
	uassert.Equal(t, int64(100), fed.Hunger)
	uassert.True(t, fed.XP >= 30) // 15 train + 15 (or 20 with Stubborn) feed
	uassert.Equal(t, int64(0), getWallet(bob).Food)
	// No food left: feeding aborts.
	urequire.AbortsContains(t, cur, "no food", func() {
		Feed(cross(cur), id)
	})
	// Forage is once per day.
	urequire.AbortsContains(t, cur, "already foraged", func() {
		ClaimFood(cross(cur))
	})
}

func TestAdventureEasy(cur realm, t *testing.T) {
	carol := testutils.TestAddress("carol")
	testing.SetOriginCaller(carol)
	id := Hatch(cross(cur), "Carol", "Storm")
	res := Adventure(cross(cur), id, "Easy")
	// Easy wild is ~50% of your power: always a win.
	uassert.True(t, strings.Contains(res, "WIN"))
	uassert.Equal(t, 2, len(dragonsOf(carol))) // starter + captured wild
	uassert.Equal(t, int64(1), getWallet(carol).Ember)
	uassert.Equal(t, int64(10), getDragon(id).XP)
	uassert.Equal(t, int64(90), getDragon(id).Hunger)
}

func TestAdventureMystery(cur realm, t *testing.T) {
	dave := testutils.TestAddress("dave")
	testing.SetOriginCaller(dave)
	id := Hatch(cross(cur), "Davey", "Frost")
	res := Adventure(cross(cur), id, "Mystery")
	uassert.True(t, strings.Contains(res, "adventure"))
	// A fourth adventure in the same day aborts (3/day cap).
	Adventure(cross(cur), id, "Easy")
	Adventure(cross(cur), id, "Easy")
	urequire.AbortsContains(t, cur, "already adventured", func() {
		Adventure(cross(cur), id, "Easy")
	})
}

func TestEvolveFailsWithoutLevel(cur realm, t *testing.T) {
	erin := testutils.TestAddress("erin")
	testing.SetOriginCaller(erin)
	id := Hatch(cross(cur), "Erin", "Stone")
	urequire.AbortsContains(t, cur, "Level 5", func() {
		Evolve(cross(cur), id)
	})
}

func TestMerge(cur realm, t *testing.T) {
	frank := testutils.TestAddress("frank")
	testing.SetOriginCaller(frank)
	base := TotalDragons()
	starter := Hatch(cross(cur), "Frankie", "Ember")
	Adventure(cross(cur), starter, "Easy")
	Adventure(cross(cur), starter, "Easy")
	uassert.Equal(t, 3, len(dragonsOf(frank)))
	wild1 := base + 1
	wild2 := base + 2
	// The soulbound starter cannot be merged away.
	urequire.AbortsContains(t, cur, "soulbound", func() {
		Merge(cross(cur), starter, wild1)
	})
	// Merge the two wild Hatchlings into a Drake.
	merged := Merge(cross(cur), wild1, wild2)
	m := getDragon(merged)
	uassert.Equal(t, int64(1), m.Rarity) // Drake
	uassert.Equal(t, int64(1), m.Level)
	uassert.Equal(t, 2, len(dragonsOf(frank))) // starter + merged
	uassert.Equal(t, base+4, TotalDragons())
}

func TestTransfer(cur realm, t *testing.T) {
	grace := testutils.TestAddress("grace")
	bob := testutils.TestAddress("bob2")
	testing.SetOriginCaller(grace)
	base := TotalDragons()
	starter := Hatch(cross(cur), "Gracie", "Storm")
	Adventure(cross(cur), starter, "Easy")
	wild := base + 1
	// Starter is soulbound.
	urequire.AbortsContains(t, cur, "soulbound", func() {
		Transfer(cross(cur), starter, bob)
	})
	// Wild dragon transfers fine.
	Transfer(cross(cur), wild, bob)
	uassert.Equal(t, bob, getDragon(wild).Owner)
	// Token.BalanceOf returns (int64, error); check the balance is 1.
	bal, err := Token.BalanceOf(bob)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(1), bal)
}

func TestTransferCap(cur realm, t *testing.T) {
	// REGRESSION: Transfer used to let a recipient exceed the 5-dragon cap.
	donor := testutils.TestAddress("donor")
	recv := testutils.TestAddress("recv")
	base := TotalDragons()
	testing.SetOriginCaller(recv)
	rStarter := Hatch(cross(cur), "Recv", "Ember")
	Adventure(cross(cur), rStarter, "Easy")
	Adventure(cross(cur), rStarter, "Easy")
	Adventure(cross(cur), rStarter, "Easy")
	uassert.Equal(t, 4, len(dragonsOf(recv))) // starter + 3 captured wilds
	testing.SetOriginCaller(donor)
	dStarter := Hatch(cross(cur), "Donor", "Storm")
	Adventure(cross(cur), dStarter, "Easy")
	Adventure(cross(cur), dStarter, "Easy")
	wild1 := base + 5
	wild2 := base + 6
	// First transfer fills recv to the cap of 5.
	Transfer(cross(cur), wild1, recv)
	uassert.Equal(t, 5, len(dragonsOf(recv)))
	// Second transfer to the capped wallet must abort.
	urequire.AbortsContains(t, cur, "already has 5 dragons", func() {
		Transfer(cross(cur), wild2, recv)
	})
	uassert.Equal(t, 5, len(dragonsOf(recv)))
	uassert.Equal(t, donor, getDragon(wild2).Owner)
}

func TestDuelSkipsOwnDragons(cur realm, t *testing.T) {
	// REGRESSION: the duel opponent pool used to include the caller's own
	// dragons, letting a player farm easy wins vs their own weak wild dragon.
	me := testutils.TestAddress("duelowner")
	other := testutils.TestAddress("duelother")
	mine := Dragon{ID: 1001, Owner: me, Level: 5, Power: 30, Speed: 30, Vitality: 30}
	theirs := Dragon{ID: 1002, Owner: other, Level: 5, Power: 30, Speed: 30, Vitality: 30}
	opp, found := pickOpponent(me, mine, []Dragon{mine, theirs}, 12345)
	uassert.True(t, found)
	uassert.Equal(t, int64(1002), opp.ID)
	_, found2 := pickOpponent(me, mine, []Dragon{mine}, 12345)
	uassert.True(t, !found2)
}

func TestXPTextMaxLevel(cur realm, t *testing.T) {
	// REGRESSION: the dragon sheet used to show "XP x / 1500 to next" at
	// Max Level 30, where there is no next level.
	uassert.True(t, strings.Contains(xpText(Dragon{Level: 30, XP: 10}), "MAX"))
	uassert.True(t, strings.Contains(xpText(Dragon{Level: 1, XP: 0}), "to next"))
}

func TestDuel(cur realm, t *testing.T) {
	heidi := testutils.TestAddress("heidi")
	testing.SetOriginCaller(heidi)
	id := Hatch(cross(cur), "Heidi", "Frost")
	before := getDragon(id).XP
	Duel(cross(cur), id)
	after := getDragon(id).XP
	// Win +20 XP, lose +5 XP.
	uassert.True(t, after-before == 20 || after-before == 5)
	uassert.Equal(t, int64(90), getDragon(id).Hunger)
}

func TestUseEquipmentNoGear(cur realm, t *testing.T) {
	ivan := testutils.TestAddress("ivan")
	testing.SetOriginCaller(ivan)
	id := Hatch(cross(cur), "Ivan", "Ember")
	urequire.AbortsContains(t, cur, "do not own", func() {
		UseEquipment(cross(cur), id, "Ember Blade")
	})
}

func TestEquipmentBonusScales(cur realm, t *testing.T) {
	// Equipment bonus is +(15 + 2 x Level): Lv1 +17, Lv10 +35, Lv20 +55, Lv30 +75.
	uassert.Equal(t, int64(17), equipmentBonus(Dragon{Level: 1}))
	uassert.Equal(t, int64(35), equipmentBonus(Dragon{Level: 10}))
	uassert.Equal(t, int64(55), equipmentBonus(Dragon{Level: 20}))
	uassert.Equal(t, int64(75), equipmentBonus(Dragon{Level: 30}))
}

func TestUseEquipmentScaledBonus(cur realm, t *testing.T) {
	// A Level 1 dragon arms +17; the same dragon at Level 10 arms +35.
	// Level up via addXP: 50 x (1+..+9) = 2250 XP takes Lv1 -> Lv10.
	leo := testutils.TestAddress("leo")
	testing.SetOriginCaller(leo)
	id := Hatch(cross(cur), "Leo", "Ember")
	w := getWallet(leo)
	addGear(&w, "Ember Blade", 1)
	saveWallet(leo, w)
	res := UseEquipment(cross(cur), id, "Ember Blade")
	uassert.True(t, strings.Contains(res, "+17"))
	d := getDragon(id)
	addXP(&d, 2250)
	uassert.Equal(t, int64(10), d.Level)
	saveDragon(d)
	w = getWallet(leo)
	addGear(&w, "Ember Blade", 1)
	saveWallet(leo, w)
	res = UseEquipment(cross(cur), id, "Ember Blade")
	uassert.True(t, strings.Contains(res, "+35"))
}

func TestHardAdventureConsumesScaledGear(cur realm, t *testing.T) {
	// Arming gear for a Hard run burns it win or lose, and the stored
	// dragon's stats are unchanged (the bonus applies to a fight-only copy).
	mia := testutils.TestAddress("mia")
	testing.SetOriginCaller(mia)
	id := Hatch(cross(cur), "Mia", "Ember")
	before := getDragon(id)
	w := getWallet(mia)
	addGear(&w, "Ember Blade", 1)
	saveWallet(mia, w)
	UseEquipment(cross(cur), id, "Ember Blade")
	Adventure(cross(cur), id, "Hard")
	after := getDragon(id)
	uassert.Equal(t, before.Power, after.Power)
	uassert.Equal(t, before.Speed, after.Speed)
	uassert.Equal(t, before.Vitality, after.Vitality)
	uassert.Equal(t, int64(0), getWallet(mia).Blades)
	uassert.Equal(t, "", getWallet(mia).ArmedItem)
}

func TestBondStreakSameDay(cur realm, t *testing.T) {
	judy := testutils.TestAddress("judy")
	testing.SetOriginCaller(judy)
	id := Hatch(cross(cur), "Judy", "Stone")
	ClaimFood(cross(cur))
	Feed(cross(cur), id)
	d := getDragon(id)
	uassert.Equal(t, int64(1), d.Streak)
	uassert.Equal(t, int64(0), d.Bond) // bond needs a 7-day streak
}

func TestRender(cur realm, t *testing.T) {
	kate := testutils.TestAddress("kate")
	testing.SetOriginCaller(kate)
	id := Hatch(cross(cur), "Katie", "Ember")
	home := Render("")
	uassert.True(t, strings.Contains(home, "Dragonhearth"))
	uassert.True(t, strings.Contains(home, "Katie"))
	sheet := Render("/dragon/" + itoa(id))
	uassert.True(t, strings.Contains(sheet, "Katie"))
	uassert.True(t, strings.Contains(sheet, "Level 1"))
	hearth := Render("/wallet/" + kate.String())
	uassert.True(t, strings.Contains(hearth, "Hearth"))
	uassert.True(t, strings.Contains(hearth, "Katie"))
	uassert.Equal(t, "404\n", Render("/nope"))
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	return s
}
