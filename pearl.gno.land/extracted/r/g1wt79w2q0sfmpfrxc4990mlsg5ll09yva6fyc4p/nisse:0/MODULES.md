Active Nisse module layout (slim).

Core loop:
- MintPlayer → TravelPlayer(attitude) → optional encounter + auto-mint companion
- BuildHouse on current tile; SetHouseSign on owned house

Files:
- `nisse.gno` — Address, Position
- `core.gno` — naming, ownership, dice
- `asset.gno` — slim companion asset registry
- `player.gno` — player, diary, companions, query helpers
- `world.gno` — map, travel
- `encounters.gno` — terrain encounters, bold/kind/cautious resolve
- `companion_mint.gno` — auto-mint on encounter success
- `building.gno` — houses, rising build cost, signs/shops
- `treasury_slim.gno` — pearls (boat / house costs)
- `watercraft.gno` — boats / water travel
- `place.gno` — optional tile names
- `tile_scene.gno` — tile describe helper (includes houses)
- `pigeonpost_slim.gno` — messaging (optional social)
