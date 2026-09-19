package nft

func SeedSamples(cur realm) {
	caller := requireUser(cur)
	if caller != admin {
		panic("nft: not admin")
	}
	if seeded {
		panic("nft: already seeded")
	}
	seeded = true
	CreateDrop(cur, "stones", "Signal Stones", "/samples/stones-01.png", 6, 500_000)
	CreateDrop(cur, "lamps", "Harbor Lamps", "/samples/lamps-01.png", 6, 800_000)
	CreateDrop(cur, "relics", "Paper Relics", "/samples/relics-01.png", 6, 1_000_000)

	id := MintIn(cur, "stones", "Ember Core", "/samples/stones-01.png")
	setRarity(id, "Legendary")
	List(cur, id, 1_000_000)
	id = MintIn(cur, "stones", "Tide Core", "/samples/stones-02.png")
	setRarity(id, "Uncommon")
	List(cur, id, 2_000_000)
	id = MintIn(cur, "stones", "Night Core", "/samples/stones-03.png")
	setRarity(id, "Rare")
	List(cur, id, 3_500_000)

	id = MintIn(cur, "lamps", "Copper Wick", "/samples/lamps-01.png")
	setRarity(id, "Common")
	List(cur, id, 1_500_000)
	id = MintIn(cur, "lamps", "Blue Wick", "/samples/lamps-02.png")
	setRarity(id, "Rare")
	List(cur, id, 2_500_000)
	id = MintIn(cur, "lamps", "Paper Wick", "/samples/lamps-03.png")
	setRarity(id, "Epic")
	List(cur, id, 4_000_000)

	id = MintIn(cur, "relics", "Folded Sun", "/samples/relics-01.png")
	setRarity(id, "Uncommon")
	List(cur, id, 1_200_000)
	id = MintIn(cur, "relics", "Folded Tide", "/samples/relics-02.png")
	setRarity(id, "Rare")
	List(cur, id, 2_200_000)
	id = MintIn(cur, "relics", "Folded Gate", "/samples/relics-03.png")
	setRarity(id, "Legendary")
	List(cur, id, 5_000_000)

	setMinted("stones", 3)
	setMinted("lamps", 3)
	setMinted("relics", 3)
}

func setMinted(slug string, n int) {
	col := mustCollection(slug)
	col.minted = n
	collections.Set(slug, col)
}
