package space

func init() {
	// Platform Links
	indexes.Link.Index(SectionPlatform, &Link{
		Title: "Tutorials",
		URL:   "section/tutorials",
	})
	indexes.Link.Index(SectionPlatform, &Link{
		Title: "News",
		URL:   "news",
	})

	// Resources Links
	indexes.Link.Index(SectionResources, &Link{
		Title: "gno.studio",
		URL:   "https://gno.studio/",
	})
	indexes.Link.Index(SectionResources, &Link{
		Title: "play.gno.land",
		URL:   "https://play.gno.land/",
	})
	indexes.Link.Index(SectionResources, &Link{
		Title: "gno.land",
		URL:   "https://gno.land/",
	})
	indexes.Link.Index(SectionResources, &Link{
		Title: "gno.docs",
		URL:   "https://docs.gno.land/",
	})

	// Social Links
	indexes.Link.Index(SectionSocials, &Link{
		Title: "YouTube",
		URL:   "", // TODO: Assign YouTube link
	})
	indexes.Link.Index(SectionSocials, &Link{
		Title: "Discord",
		URL:   "", // TODO: Add Discord link
	})

	// Ecosystem Tool
	// TODO: Add IPFS links to tool icons
	tools = []*Tool{
		{
			Name:        "Gno.Studio",
			URL:         "https://gno.studio/",
			Description: "A premier builder experience with a full-featured IDE and smart contract templates.",
		},
		{
			Name:        "Adena Wallet",
			URL:         "https://www.adena.app/",
			Description: "Adena is a friendly, open-source, non-custodial Gnoland wallet, built for Gnomes worldwide.",
		},
		{
			Name:        "Gno Studio Connect",
			URL:         "https://gno.studio/connect",
			Description: "Simplifies interaction with Gno smart contract functions.",
		},
		{
			Name:        "Gno Playground",
			URL:         "https://play.gno.land/",
			Description: "A minimalist IDE for creating, testing, deploying, and sharing Gno code",
		},
		{
			Name:        "GnoDev",
			URL:         "https://docs.gno.land/gno-tooling/cli/gno-tooling-gnodev/",
			Description: "Quick and efficient development of Gno code.",
		},
		{
			Name:        "GnoScan",
			URL:         "https://gnoscan.io/",
			Description: "Gnoscan is a Gnoland blockchain explorer, making on-chain data readable and intuitive.",
		},
	}
}
