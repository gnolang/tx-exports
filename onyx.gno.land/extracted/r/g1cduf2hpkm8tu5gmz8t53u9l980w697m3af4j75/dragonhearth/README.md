# Dragonhearth

A dragon-progression game realm for the Gnome Tavern Hackathon by Gno.land.

Hatch a free soulbound dragon, train and feed it daily, win wild dragons on
adventure, evolve it with adventure shards, and merge duplicates up a rarity.
Dragons are canonical GRC721 tokens (`DRGN`); the starter is soulbound, wild
dragons are tradeable. No true randomness — every roll derives from block
height + caller address.

## Play (gnokey, local devnet)

```sh
gnokey maketx call -pkgpath gno.land/r/velt/dragonhearth -func Hatch \
  -args "Ember" -args "Ember" \
  -gas-fee 500000ugnot -gas-wanted 20000000 -max-deposit 1000000ugnot \
  -chainid dev -remote 127.0.0.1:26657 <keyname>
```

Then: `Train(id, stat)` (3/day), `ClaimFood()` (1/day), `Feed(id)`,
`Adventure(id, tier)` — Easy/Normal/Hard/Mystery (3/day),
`Evolve(id)`, `Merge(id1, id2)`, `Duel(id)` (3/day),
`UseEquipment(id, item)` (Hard runs only), `Transfer(id, to)`.

The game page is `Render()` — open the realm in gnoweb. Dragon sheets live at
`:dragon/<id>`, hearths at `:wallet/<address>`.

## Rules (locked)

- 1 free soulbound Hatchling per wallet; max 5 dragons per wallet.
- Rarities: Hatchling → Drake → Wyrm → Ancient → Mythic. Max Level 30,
  Mythic at 20; XP to next level = 50 × Level.
- Train: instant, 50-block cooldown, +2 stat, +10 XP (+5 on element stat),
  costs 10 Hunger. Feed: +15 XP, +1 Growth, +30 Hunger.
  Below 30 Hunger: half training XP, −20% Power.
- Adventure wins capture the wild dragon: Easy ~50% of your Power,
  Normal 90–100%, Hard 130–150%, Mystery rolls a tier at entry.
- Equipment is consumable, Hard only, 1 per run, burned win or lose:
  Ember Blade +(15 + 2 × Level) Power, Frost Shield +(15 + 2 × Level)
  Vitality, Swift Charm +(15 + 2 × Level) Speed (Lv1 +17, Lv10 +35,
  Lv20 +55, Lv30 +75). The bonus scales so gear stays relevant as
  dragons level up.
- Evolve (guaranteed): Lv5 + 5 Ember → Drake; Lv10 + 8 Frost → Wyrm;
  Lv15 + 12 Storm → Ancient; Lv20 + 10 Mystery → Mythic.
- Merge: 2 same-rarity (not the starter) → 1 next rarity, stats average +5.
- Bond streaks: feed the same dragon 7 days straight → +1 Bond, +2 Growth;
  missing a day resets the streak.

## Build & test

```sh
export GNOROOT=$HOME/.gno/src PATH="$HOME/.gno/bin:$PATH"
gno fmt ./... && gno lint ./... && gno test ./...
```

Local `gno.land/p/...` deps resolve from the module cache
(`~/.config/gno/pkg/mod/`, see LEARN.md for the marker-file gotcha).
