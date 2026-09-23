package home

// defaultCrew seeds the roster at deploy time: everyone who contributed to
// gno with samcrew over the last four years, team by team, in the order the
// cards appear. Former members are in the alumni team, drawn in grey. Cards link to a public page until LinkProfile ties a member to their
// gno.land identity.
const (
	gh        = "https://github.com/"
	aboutCrew = "https://www.samourai.world/about/"
)

func defaultCrew() []struct{ id, handle, role, team, url string } {
	return []struct{ id, handle, role, team, url string }{
		{"zxxma", "zôÖma", "Founder, CEO & CTO", "engineering", gh + "zxxma"},
		{"gh0st", "gh0st", "GnoVM core · 62 PRs in gno", "engineering", gh + "omarsy"},
		{"mikecito", "mikecito", "GnoVM · 39 PRs in gno", "engineering", gh + "Villaquiranm"},
		{"mikael", "Mikael Vallenet", "gno.land & GnoVM · 41 PRs", "engineering", gh + "mvallenet"},
		{"lours", "lours", "Validators & DevOps", "engineering", gh + "louis14448"},
		{"david", "david", "DevRel · 70 PRs in gno", "engineering", gh + "davd-gzl"},
		{"yohann", "Yohann G.", "Co-founder · Film director", "media", aboutCrew},
		{"fanny", "Fanny Z.", "Film maker · Photographer", "media", aboutCrew},
		{"thomas", "Thomas I.", "Film maker · Media director", "media", aboutCrew},
		{"oriane", "Oriane T.", "Photographer · Reporter", "media", aboutCrew},
		{"n0izn0iz", "n0izn0iz", "gno.land · Teritori · Zenao", "alumni", gh + "n0izn0iz"},
		{"dadidou", "dadidou", "Front-end · Teritori · Zenao", "alumni", gh + "WaDadidou"},
		{"moonia", "moonia", "gnolove · gnodaokit · Zenao", "alumni", gh + "moonia"},
		{"hthieu1110", "hthieu1110", "GnoVM · 8 PRs · Teritori", "alumni", gh + "hthieu1110"},
		{"omniwired", "omniwired", "tm2 · Teritori", "alumni", gh + "omniwired"},
		{"amozpay", "AmozPay", "DevOps · gno docs", "alumni", gh + "AmozPay"},
	}
}

// defaultProfiles are the members already on chain.
func defaultProfiles() []struct {
	id   string
	addr address
	home string
	line string
} {
	return []struct {
		id   string
		addr address
		home string
		line string
	}{
		{"zxxma", "g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c", "/r/g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c/home", "<3 is the encryption key."},
	}
}

const memba = "https://memba.samourai.app/mainnet"

var hero = heroText{
	kicker:   "SAMOURAÏ COOP · GNO.LAND · PARIS",
	title:    "samcrew",
	subtitle: "The gno.land crew of Samouraï Coop",
	tagline:  "core contributors · genesis validator · design partner",
	footline: "film crew · engineering studio · since 2016",
	alt:      "samcrew, the gno.land crew of Samouraï Coop",
}

// defaultSlots and defaultGalleries seed the page at deploy time. They are
// functions, not package variables, so the seed text is stored once (in the
// slot and gallery trees) instead of twice. After deploy the chain is the
// source of truth: edit with Set and SetGallery, not by redeploying.
func defaultSlots() []struct{ slug, body string } {
	return []struct{ slug, body string }{
		{"layout", `:hero:

:intro:

## 道 Core contributors, four years running

:core:

## 源 Open source

:oss:

:gallery.oss:

## 作 Products

:products:

:gallery.products:

## 組 Inside Memba

:memba:

:gallery.memba:

## 守 What we run

:run:

## 侍 The crew

:crew:

## 録 gno.land on film

:gnofilm:

:gallery.gno:

## 祭 Events

:events:

:gallery.events:

## 報 Contribution reports

:reports:

:gallery.reports:

## 学 Peer Dev: gno.land, taught on video

:peerdev:

:gallery.peerdev:

## 旅 WEB TRIP

:webtrip:

:gallery.webtrip:

## 映 Films by the crew

:films:

:gallery.films:

## 記 From the blog

:blog:

:gallery.blog:

## 印 On chain

:packages:

## 門 Find us

:contact:

---

*This page is a contract.* ` + "`:realm:`" + ` · rev :rev: · block :height: on :chainid: · every poster on it is drawn on chain · [slots](/r/samcrew/home:slots)

:ascii:
`},

		// The Samouraï Coop mark again, as a sign-off, drawn in half blocks from
		// the logo's own pixels.
		{"ascii", "```" + `
              ▄▄▄██████████▄▄▄
          ▄▄████████████████████▄▄
       ▄▄██████████████████████████▄▄
     ▄████████████████████████████████▄
    ████████████████████████████████████
         ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ▄▄                                    ▄▄
 ████████      ▄▄▄▄▄▄▄▄▄▄▄▄▄      █████████
▄████████      █████████████      █████████▄       S A M O U R A Ï   C R E W
▀▀▀▀▀▀▀▀▀      ▀▀▀▀▀▀▀▀▀▀▀▀▀      ▀▀▀▀▀▀▀▀▀▀
                                                   film crew · engineering studio
████████       █████████████▄      █████████       gno.land core contributors
▀▀▀▀▀▀▀▀      ▄██████████████      █████████       Paris · since 2016
              ███████████████      ████████▀
 ██████▀      ███████████████       ▀██████
  █████       ███████████████         ▀███
   ████       ███████████████       ▄   ▀
    ▀██       ███████████████       ▀█▄
     ▀        ███████████████        █▀
              ███████████████
             ▄████████████████
              ▀▀▀██████████▀▀
` + "```"},

		{"intro", `> **samcrew** is the gno.land team of [Samouraï Coop](https://www.samourai.world), a worker cooperative from Paris that is a film crew and an engineering studio in one company.

We contribute to the chain's core, run one of its genesis validators, build our own products on it as a design partner, research how organisations govern themselves, and film the ecosystem as it grows.`},

		{"core", `The crew has **[256 merged pull requests in gnolang/gno](https://github.com/gnolang/gno/pulls?q=is%3Apr+is%3Amerged+author%3Aomarsy+author%3AVillaquiranm+author%3Amvallenet+author%3Adavd-gzl+author%3An0izn0iz+author%3Ahthieu1110+author%3Amoonia+author%3AWaDadidou+author%3Aomniwired+author%3AAmozPay)**, about one in eleven of every PR merged there, and more each year: 48 in 2024, 79 in 2025, 128 so far in 2026.

| | what we do |
| --- | --- |
| **GnoVM** | The interpreter, its type checker, stdlibs and test suite. |
| **Security** | Hardening the VM, consensus and p2p against crashes, overflows and malformed input. |
| **Chain & tooling** | gno.land node, tm2, genesis tools, ` + "`gnodev`" + `, docs. |
| **Validators** | A genesis validator, [gnomonitoring](https://github.com/samouraiworld/gnomonitoring), [validator tooling](https://github.com/samouraiworld/gno-validator-tools) and the [katana](https://github.com/samouraiworld/katana) GovDAO daemon. |
| **Governance research** | Our [research lab](https://samouraiworld.github.io/gov-research-wiki/) studies cooperatives, DAOs and open-source projects. [gnodaokit](https://github.com/samouraiworld/gnodaokit) and Memba are its output. |
| **Design partner** | We ship our own products on gno.land and send what they teach us back upstream. |
| **Documentation** | Retreat and event reports for the core team, the Peer Dev tutorials, the WEB TRIP interviews. |`},

		{"run", `- **A genesis validator.** One of the four validators securing ` + "`gnoland-1`" + ` since mainnet launch on 12 September 2026.
- **Validator monitoring.** [gnomonitoring](https://github.com/samouraiworld/gnomonitoring) watches the chain and pages the humans.
- **GovDAO tooling.** [katana](https://github.com/samouraiworld/katana) automates validator ejection for GovDAO.`},

		{"products", `Products built and run by the coop. The live ones are open to anyone.`},

		{"memba", `[Memba](https://memba.samourai.app) is an experimental operating system for decentralised organisations, and the direct output of our governance research. It is MIT-licensed and [open source](https://github.com/samouraiworld/memba). Each of its parts is a product in its own right. Hover a card for details.

Every game uses one daily seed for everyone, drawn from a gno.land block, and needs no wallet.`},

		{"gnofilm", `The crew films gno.land from the inside: brand films, core-team retreats, portraits of the teams building on it.`},

		{"oss", `Everything we can open, we open. These are our public gno repositories on [GitHub](https://github.com/samouraiworld).`},

		{"events", `We produce the events we believe in, and we film the rest of the ecosystem's. **Paris P2P Festival**: five days of peer-to-peer at Ground Control, free, for 5,000 people. The Édition #1 talks are [all online](https://p2p.samourai.tv). **Hyper Hacktive Festival**: a film festival for independent documentaries funded by Samouraï Grants. It has had three editions, two at mk2 Quai de Seine, and sells its tickets on Zenao.`},

		{"reports", `Each year, one film shows everything the coop shipped.`},

		{"peerdev", `A 17-lesson curriculum, produced end to end by the coop, that takes a developer from an empty machine to GovDAO and the interrealm spec. Watch it on [the Peer Dev channel](https://www.youtube.com/@peerdevlearning) or as [one playlist](https://www.youtube.com/playlist?list=PLJZrQikyfMc-kBojXgAojOz4UQPuq4DiY).`},

		{"webtrip", `Eight conversations with gno.land and web3 builders, filmed by the crew in 2024.`},

		{"films", `40 festival selections, 3 wins. [The Underground Sistine Chapel](https://www.youtube.com/watch?v=fsRFHmdiyGE) took Best Documentary at the London Independent Film Awards and was released free on both IPFS and YouTube.`},

		{"blog", `Research notes, essays and product write-ups from the coop. [All posts](https://www.samourai.world/blog/) · [RSS](https://www.samourai.world/blog/rss.xml)`},

		{"packages", `**Realms:** [App Store](/r/samcrew/memba_appstore_v3) · [feed](/r/samcrew/memba_feed_v1) · [DAO channels](/r/samcrew/memba_dao_channels_v2) · [quests](/r/samcrew/memba_quest_attestation_v1) · [reviews](/r/samcrew/memba_reviews_v2) · [feedback](/r/samcrew/memba_feedback_v2) · [escrow](/r/samcrew/escrow_v3) · [market config](/r/samcrew/memba_market_config) · [arcade leaderboard](/r/samcrew/memba_arcade_leaderboard_v1) · [GnoBuilders badges](/r/samcrew/gnobuilders_badges_v2)

**Libraries:** [avl](/p/samcrew/avl) · [piechart](/p/samcrew/piechart/v0) · [tablesort](/p/samcrew/tablesort/v0) · [urlfilter](/p/samcrew/urlfilter/v0)`},

		{"contact", `[samourai.world](https://www.samourai.world) · [GitHub](https://github.com/samouraiworld) · [Samouraï TV](https://www.youtube.com/channel/UC0gExSSzyU8gTqUjoYerI8A) · [Peer Dev](https://www.youtube.com/@peerdevlearning) · [X](https://www.twitter.com/samouraicoop) · [Telegram](https://t.me/samouraicoop) · hello@samourai.coop`},
	}
}

const (
	yt   = "https://www.youtube.com/watch?v="
	ghsw = "https://github.com/samouraiworld/"
)

func defaultGalleries() []struct{ name, spec string } {
	return []struct{ name, spec string }{
		{"gno", `
gno | Gno: The Power To Build What Matters | gno.land · brand film | ` + yt + `M920PO3yrHk
gno | Alignment Retreat, Turin | gno.land core team · retreat report | ` + yt + `3czMK3s30KQ
gno | Inside Onbloc | gno.land · team portrait · Nov 2024 | ` + yt + `7umxHYDJ4Bk
`},

		{"products", `
product | Memba | Experimental · organizations OS | https://memba.samourai.app
product | Zenao | Beta · ticketing & communities | https://zenao.io
product | gnolove | Live · who builds gno.land | https://gnolove.world
product | Visio | Live · video meetings, no account | https://visio.samourai.app
product | Greffon | Beta · self-host in one click | https://greffon.io
product | Reportz | Live · the commons, from GitHub | https://reportz.dev
product | Coop Nation | Live · the cooperative manifesto | https://coopnation.fr
product | AlarmFriends | Soon · friends wake you up | https://alarmfriends.samourai.app
`},

		{"memba", `
memba | Multisig Wallet | For organizations · Adena & gnokey | ` + memba + `/multisig | Create or import a multisig, propose sends and contract calls, collect signatures from Adena or gnokey, then broadcast.
memba | DAO Management | Create, vote, execute · GovDAO | ` + memba + `/dao | Browse GovDAO and community DAOs, vote, execute, create your own and talk in DAO channels.
memba | Validator Monitoring | Reliability scores · hacker view | ` + memba + `/validators | Every validator scored for reliability, plus a live consensus hacker view.
memba | Alerting | GovDAO & validators · 3 channels | ` + memba + `/alerts | GovDAO and validator alerts on Discord, Slack and Telegram.
memba | On-chain App Store | Registry · submissions · curation | ` + memba + `/apps | The ecosystem's apps, with an on-chain registry, submissions and curation.
memba | Directory | DAOs · realms · packages · users | ` + memba + `/directory | Search DAOs, realms, packages, tokens and users, with source and render side by side.
memba | Dev Reports | gnolove scoreboard · weekly reports | ` + memba + `/gnolove | The gnolove contributor scoreboard, weekly reports and team analytics.
memba | Token Launcher | GRC20 · browse & launch | ` + memba + `/tokens | Browse GRC20 tokens and launch your own.
memba | Social Feed | On-chain posts · open moderation | ` + memba + `/feed | An on-chain social feed with a public moderation log.
memba | Quests & Badges | GnoBuilders · 85 quests · 8 ranks | ` + memba + `/quests | GnoBuilders: 85 quests, 8 ranks, a leaderboard and on-chain badges.
game | Space Invaders | Daily or free play · no wallet | ` + memba + `/game/space-invaders | Marching waves, combos, a mystery UFO and destructible bunkers. Daily or free play, keyboard or touch.
game | Block Party | Daily 4×4 merge · seeded by a block | ` + memba + `/game | A daily tile-merge puzzle. Everyone gets the same board, seeded from a real gno.land block. Streaks and a daily leaderboard.
game | BARRICADE | 90-second lane defence · 8 waves | ` + memba + `/game/barricade | Hold the barricade against The Order for 8 waves up to the Broadcast Tower, then an endless siege. Runs can be certified on chain.
`},

		{"oss", `
oss | memba | Multisig & DAO governance for gno.land | ` + ghsw + `memba
oss | gnolove | The gno.land contributor scoreboard | ` + ghsw + `gnolove
oss | zenao | Event ticketing & communities | ` + ghsw + `zenao
oss | gnodaokit | A framework for DAOs in Gno | ` + ghsw + `gnodaokit
oss | gnomonitoring | Monitoring for gno validators | ` + ghsw + `gnomonitoring
oss | katana | GovDAO validator-ejection daemon | ` + ghsw + `katana
oss | gno-validator-tools | Validators & sentries as code | ` + ghsw + `gno-validator-tools
oss | gov-research-wiki | The governance research lab | ` + ghsw + `gov-research-wiki
oss | peerdev | The Peer Dev channel, in the open | ` + ghsw + `peerdev
oss | validator-diagnostics | The validator fire-drill portal | ` + ghsw + `validator-diagnostics
oss | gno-onboarding-bot | Validator onboarding, on Discord | ` + ghsw + `gno-onboarding-bot
oss | gno-govdao-activity-parser | GovDAO voter activity & test env | ` + ghsw + `gno-govdao-activity-parser
`},

		{"events", `
festival | Paris P2P Festival | Co-founded by zôÖma · Ground Control | ` + yt + `PQ9I73tJobU
festival | Hyper Hacktive Festival | 3 editions · mk2 Quai de Seine | https://hyperhacktive.io
event | Web3 Summit | Web3 Foundation · Berlin 2024-25 | ` + yt + `PRG0cnV7YG8
event | dWeb Camp | Internet Archive · California 2022 | ` + yt + `zx7Dduv0Hd4
event | Funding the Commons | San Francisco · Buenos Aires | ` + yt + `bOZrUha9aQ8
`},

		{"reports", `
report | Contribution Report 2025 | Samouraï Coop · Welcome to 2026 | ` + yt + `aG4M37FX4II
report | Contribution Report 2024 | Samouraï Coop · Welcome to 2025 | ` + yt + `37L4vULszLQ
report | Contribution Report 2023 | Samouraï Coop · Welcome to 2024 | ` + yt + `tj0imGVJHQc
`},

		{"peerdev", `
peerdev | Setup your local environment | Lesson 1 | ` + yt + `C8RuA_uU3Fs
peerdev | Build and test your first dApp | Lesson 2 | ` + yt + `nzo6QgxQHgw
peerdev | Register your User Space | Lesson 3 | ` + yt + `R5t1GmBRUVk
peerdev | Transaction types | call · run · addpkg · send | ` + yt + `-Z3M1XVxWU8
peerdev | Coins and GRC20 | Lesson 5 | ` + yt + `4twoUyjo4rA
peerdev | AVL tree vs map | Lesson 6 | ` + yt + `Qh73MqxxKTM
peerdev | Deploying Gno packages | Lesson 7 | ` + yt + `B7bSreCwIls
peerdev | Interactive documentation | Lesson 8 | ` + yt + `zpGxMQo3V-o
peerdev | Effective programming in Gno | Lesson 9 | ` + yt + `UNJSuMdjTFA
peerdev | Interrealm specification | Lesson 10 | ` + yt + `JJju7-GeRbA
peerdev | DAOs and modular governance | Lesson 11 | ` + yt + `SphPgsjKQyQ
peerdev | Governance DAO (GovDAO) | Lesson 12 | ` + yt + `jM-6ezyn_v4
peerdev | Index your transactions | tx-indexer | ` + yt + `8ld0nsV37SA
peerdev | Monitor your validator | gnomonitoring | ` + yt + `ujwbKSFS_wg
peerdev | Extend your IDE | VS Code · Neovim · Emacs · JetBrains | ` + yt + `Ssk1m-YGnyo
peerdev | Secure your wallet | Lesson 16 | ` + yt + `q2jlN8KXBMA
peerdev | Gno vs Solidity | Lesson 17 | ` + yt + `Oi77hvJCVbU
`},

		{"webtrip", `
webtrip | #1 Creating a New Era with Gno | Manfred Touron · gno.land | ` + yt + `Hv2QSIjz_U8
webtrip | #2 Building Trust in Web3 | Isaac Patka · Shield3 | ` + yt + `hKc9eWU2_CI
webtrip | #3 Digital Art Disruptors | Distributed Gallery | ` + yt + `4nvVak97eik
webtrip | #4 Decentralizing Digital Communities | Morgan Bazalgette · gno.land | ` + yt + `Hprl2WkMYCA
webtrip | #5 Bridging Web2 and Web3 | Dongwon Shin · Onbloc | ` + yt + `-kb_N4Y7cm0
webtrip | #6 The Future of Staking and NFTs | Adrien Faguet · StakeLab | ` + yt + `0cOdIoQ1npI
webtrip | #7 Personal Development and Blockchain | Dragos Roua | ` + yt + `aw8SJajzRdA
webtrip | #8 Work-Life Balance & Product Design | Diane | ` + yt + `r_S9YbwF9UM
`},

		{"blog", `
blog | Gno.land in 2026: the beta mainnet | 27 Aug 2026 · gno.land | https://www.samourai.world/blog/gno-land-in-2026-what-a-beta-mainnet-actually-means/ | The chain is live and the token cannot move yet: what has shipped, what has not, and what the project has actually promised.
blog | Samouraï Governance Research Lab | 5 Nov 2025 · governance | https://www.samourai.world/blog/samoura%C3%AF-governance-research-lab-une-nouvelle-%C3%A9tape-pour-la-coop%C3%A9rative/ | The coop opens a research lab on cooperative and distributed governance, after eight years of building.
blog | Decentralized governance or the classic model | 7 Jan 2026 · governance | https://www.samourai.world/blog/decentralized-governance-vs-classic-model/ | Decentralized (DAO, blockchain) and classic governance compared: advantages, limits, costs and use cases.
blog | Crypto (Anti-)Commons? Part 1 | 23 Jun 2026 · research | https://www.samourai.world/blog/crypto-anti-commons-controversies-surrounding-the-status-of-bitcoin-and-public-blockchains-as-dig/ | Can Bitcoin and public blockchains be called digital commons? Part 1 maps the controversy.
blog | Cooperative & Web3 Glossary | 13 Jan 2026 · research | https://www.samourai.world/blog/cooperative-web3-glossary-v-0-1/ | A living glossary translating between cooperative and Web3 vocabularies, for coops meeting the DAO and Web3 builders meeting the coop.
blog | Insight Report #1: Phil H. | 12 Dec 2025 · interview | https://www.samourai.world/blog/insight-report-series-external-interview-1-phil-h/ | The first of an interview series on distributed governance.
blog | From Startup Nation to Coop Nation | 4 Sep 2026 · essay | https://www.samourai.world/blog/from-startup-nation-to-coop-nation/ | Signs of a public and cooperative tech awakening in France, the risks of sovereignty washing, and how to take part.
blog | Reportz: the digital commons, live | 31 Aug 2026 · product | https://www.samourai.world/blog/reportz-who-builds-the-digital-commons-live-from-github/ | A contribution board built from the public GitHub API: what it counts, and what it refuses to count.
blog | Greffon: self-hosted deployment | 5 Aug 2026 · product | https://www.samourai.world/blog/greffon-io-self-hosted-deployment-platform/ | A technical tour of Greffon: its control plane, workers and built-in certificate authority.
`},

		{"films", `
film | The Underground Sistine Chapel | Feature documentary · 2021 | ` + yt + `fsRFHmdiyGE
film | Hashiriya | Documentary · 2025 | ` + yt + `OqMTmSEbqqY
film | Soy Yo | Documentary · 2025 | ` + yt + `fWE2fpZuDEM
film | Mañana cuesta más | Documentary · 2026 | ` + yt + `PEAR7l8dGEk
film | Community Networks | Documentary · 2024 | ` + yt + `JuHVteEhNzo
film | I'm Just a Lost Guy | Short film · 2025 | ` + yt + `84RgQxdI3n8
`},
	}
}
