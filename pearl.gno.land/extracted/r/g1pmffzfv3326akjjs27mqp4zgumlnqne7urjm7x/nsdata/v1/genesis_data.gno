package nsdata

// GENERATED FILE — do not hand-edit. Rebuild with:
//
//     node tools/snapshot.js && python3 tools/freeze-genesis.py
//
// Frozen from pearl-1 at height 348905, snapshot taken 2026-09-10T23:18:21.664Z.
// 53 domains, 3 globals. Left out: granter.

func genesisConfig() genesisCfg {
	return genesisCfg{
		termLength:       31536000,
		gracePeriod:      7776000,
		minLabelLen:      1,
		maxLabelLen:      63,
		maxExtraKeyLen:   32,
		maxExtraValueLen: 512,
		maxExtraEntries:  24,
		maxDeletePerCall: 100,
	}
}

func genesisGlobals() [][2]string {
	return [][2]string{
		{"cardfx", "from:12-31;to:01-01;dir:burst;n:5;c:#f87171;c2:#facc15;c3:#60a5fa;k:10;s:3;d:9|from:12-01;to:01-06;dir:fall;n:26;c:#ffffff;c2:#dbeafe;sv:2;s:3;d:11|from:10-24;to:11-02;dir:rise;n:22;c:#f97316;c2:#facc15;s:2;d:8|from:09-25;to:10-23;dir:fall;n:18;c:#f59e0b;c2:#b45309;c3:#dc2626;sh:leaf;sv:1;s:4;d:12|from:03-15;to:04-15;dir:fall;n:16;c:#f9a8d4;c2:#fce7f3;c3:#fbcfe8;sh:petal;s:3;d:13|from:09-01;to:09-07;dir:fall;n:30;c:#22d3ee;c2:#f472b6;c3:#facc15;s:3;d:7"},
		{"refcut", "0:5,1:10,2:15,3:20,4:25,5:30"},
		{"refdisc", "0:5,1:6,2:7,3:8,4:9,5:10"},
	}
}

func genesisDomains() []genesisDomain {
	return []genesisDomain{
		{"1337", nil},
		{"420", nil},
		{"69", nil},
		{"alpha", nil},
		{"anon", nil},
		{"ape", nil},
		{"atom", nil},
		{"based", nil},
		{"beta", nil},
		{"bitcoin", nil},
		{"btc", nil},
		{"buidl", nil},
		{"chad", nil},
		{"cooked", nil},
		{"cope", nil},
		{"cosmos", nil},
		{"crypto", nil},
		{"degen", nil},
		{"doge", nil},
		{"eth", nil},
		{"fomo", nil},
		{"fren", nil},
		{"frog", [][2]string{
			{"open", "0"},
		}},
		{"gm", nil},
		{"gn", nil},
		{"gnoland", nil},
		{"gnome", nil},
		{"gnot", nil},
		{"goat", nil},
		{"hodl", nil},
		{"king", nil},
		{"lambo", nil},
		{"meme", [][2]string{
			{"free", "1"},
		}},
		{"mid", nil},
		{"moon", nil},
		{"nft", nil},
		{"ngmi", nil},
		{"og", nil},
		{"omega", nil},
		{"pepe", nil},
		{"photon", nil},
		{"pleb", nil},
		{"rekt", nil},
		{"rich", nil},
		{"ser", nil},
		{"sol", nil},
		{"soon", nil},
		{"sus", nil},
		{"thoon", nil},
		{"troll", nil},
		{"wagie", nil},
		{"wagmi", nil},
		{"whale", nil},
	}
}
