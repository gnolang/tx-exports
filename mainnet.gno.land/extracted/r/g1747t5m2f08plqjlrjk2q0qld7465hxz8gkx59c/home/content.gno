package home

// defaultSlots and defaultGalleries seed the page at deploy time. After that
// the chain is the source of truth: edit with Set and SetGallery, not by
// redeploying.

const home = "/r/g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c/home"

const memba = "https://memba.samourai.app/mainnet"

var hero = heroText{
	kicker:   "SAMOURAÏ COOP · GNO.LAND · PARIS",
	title:    "zôÖma",
	subtitle: "Founder, CEO & CTO of Samouraï Coop",
	tagline:  "<3 is the encryption key.",
	footline: "film crew · engineering studio · gno.land core contributors",
	alt:      "zôÖma, Founder, CEO & CTO of Samouraï Coop",
}

var defaultSlots = []struct{ slug, body string }{
	{"layout", `:hero:

<gno-columns>
![zôÖma](https://avatars.githubusercontent.com/u/37345040?s=400)
<gno-columns-sep />
:bio:

:social:
</gno-columns>

## 今 Now

:now:

## 道 Four years in the gno.land core

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

## 数 Numbers

:numbers:

## ♥ <3 is the encryption key

:hearts:

---

*This page is a contract.* ` + "`:realm:`" + ` · rev :rev: · block :height: on :chainid: · every poster on it is drawn on chain · [slots](` + home + `:slots)
`},

	{"bio", `**Founder, CEO & CTO of [Samouraï Coop](https://www.samourai.world)**, a worker cooperative from Paris that is a film crew and an engineering studio in one company, building and promoting open-source culture since 2016.

Co-founder of the [Paris P2P Festival](https://p2p.samourai.tv). For more than 12 years I've worked across the peer-to-peer, cybersecurity and open-source ecosystems, researching and building decentralized organizations. Alongside the coop, I lead **samcrew**, our gno.land team: core contributors to GnoVM and the gno.land chain, and one of its genesis validators. I also build [Memba](https://memba.samourai.app).`},

	{"social", `[GitHub](https://github.com/zxxma) · [samourai.world](https://www.samourai.world) · [Samouraï TV](https://www.youtube.com/channel/UC0gExSSzyU8gTqUjoYerI8A) · [X](https://www.twitter.com/samouraicoop) · [the crew](/u/samcrew)`},

	{"now", `- **Holding the line.** samcrew runs one of the four validators securing ` + "`gnoland-1`" + `, live since mainnet launch on 12 September 2026.
- **Memba, on mainnet.** 14 samcrew packages are live, from the [App Store](/r/samcrew/memba_appstore_v3) to [escrow](/r/samcrew/escrow_v3) and an [arcade leaderboard](/r/samcrew/memba_arcade_leaderboard_v1).
- **Filming the chain.** The crew keeps documenting gno.land: retreats, events, builders.`},

	{"core", `Samouraï Coop has contributed to the gno.land core for more than four years. The crew has **[256 merged pull requests in gnolang/gno](https://github.com/gnolang/gno/pulls?q=is%3Apr+is%3Amerged+author%3Aomarsy+author%3AVillaquiranm+author%3Amvallenet+author%3Adavd-gzl+author%3An0izn0iz+author%3Ahthieu1110+author%3Amoonia+author%3AWaDadidou+author%3Aomniwired+author%3AAmozPay)**, about one in eleven of every PR ever merged there, and more each year: 48 in 2024, 79 in 2025, 128 so far in 2026.

| | what we do |
| --- | --- |
| **GnoVM** | The interpreter, its type checker, stdlibs and test suite: most of our upstream work. |
| **Security** | Hardening the VM, consensus and p2p against crashes, overflows and malformed input. |
| **Chain & tooling** | gno.land node, tm2, genesis tools, ` + "`gnodev`" + `, docs. |
| **Validators** | A genesis validator, [gnomonitoring](https://github.com/samouraiworld/gnomonitoring) and the [katana](https://github.com/samouraiworld/katana) GovDAO daemon. |
| **Governance research** | Our [research lab](https://samouraiworld.github.io/gov-research-wiki/) studies how cooperatives, DAOs and open-source projects govern themselves. [gnodaokit](https://github.com/samouraiworld/gnodaokit) and Memba are its output. |
| **Design partner** | We build our own products on gno.land and send what they teach us back upstream. |
| **Documentation** | Retreat and event reports for the core team, the Peer Dev tutorials, the WEB TRIP interviews. |`},

	{"oss", `Everything we can open, we open. Our public gno repositories are on [GitHub](https://github.com/samouraiworld); the whole team page is at [/u/samcrew](/u/samcrew).`},

	{"gnofilm", `The crew films gno.land from the inside: brand films, core-team retreats, portraits of the teams building on it.`},

	{"products", `Products built and run by the coop, closest to gno.land first.`},

	{"memba", `[Memba](https://memba.samourai.app) is an experimental operating system for decentralised organisations, and the direct output of our governance research. It is MIT-licensed and [open source](https://github.com/samouraiworld/memba). Each of its parts is a product in its own right. Hover a card for details.

Every game uses one daily seed for everyone, drawn from a gno.land block, and needs no wallet.`},

	{"events", `We produce the events we believe in, and we film the rest of the ecosystem's. **Paris P2P Festival**: five days of peer-to-peer at Ground Control, free, for 5,000 people. The Édition #1 talks are [all online](https://p2p.samourai.tv). **Hyper Hacktive Festival**: a film festival for independent documentaries funded by Samouraï Grants. It has had three editions, two at mk2 Quai de Seine, and sells its tickets on Zenao.`},

	{"reports", `Each year, one film shows everything the coop shipped.`},

	{"peerdev", `A 17-lesson curriculum, produced end to end by the coop, that takes a developer from an empty machine to GovDAO and the interrealm spec. [Watch the playlist](https://www.youtube.com/playlist?list=PLJZrQikyfMc-kBojXgAojOz4UQPuq4DiY).`},

	{"webtrip", `Eight conversations with gno.land and web3 builders, filmed by the crew in 2024.`},

	{"films", `40 festival selections, 3 wins. [The Underground Sistine Chapel](https://www.youtube.com/watch?v=fsRFHmdiyGE) took Best Documentary at the London Independent Film Awards and was released free on both IPFS and YouTube.`},

	{"numbers", `| since day one | |
| --- | ---: |
| Crew PRs merged in gnolang/gno | 256 |
| My merged pull requests, all repos | 2,941 |
| …of which into Memba | 1,018 |
| samcrew packages live on ` + "`gnoland-1`" + ` | 14 |
| Projects delivered by the coop since 2016 | 500+ |
| Festival selections · wins | 40 · 3 |
| Peer Dev tutorials | 17 |
| Contributing on Gno since | 2022 |

*Counted from GitHub, the chain and samourai.world on 23 September 2026.*`},
}

const (
	yt = "https://www.youtube.com/watch?v="
	gh = "https://github.com/samouraiworld/"
)

var defaultGalleries = []struct{ name, spec string }{
	{"gno", `
gno | Gno: The Power To Build What Matters | gno.land · brand film | ` + yt + `M920PO3yrHk
gno | Alignment Retreat, Turin | gno.land core team · retreat report | ` + yt + `3czMK3s30KQ
gno | Inside Onbloc | gno.land · team portrait · Nov 2024 | ` + yt + `7umxHYDJ4Bk
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
oss | memba | Multisig & DAO governance for gno.land | ` + gh + `memba
oss | gnolove | The gno.land contributor scoreboard | ` + gh + `gnolove
oss | zenao | Event ticketing & communities | ` + gh + `zenao
oss | gnodaokit | A framework for DAOs in Gno | ` + gh + `gnodaokit
oss | gnomonitoring | Monitoring for gno validators | ` + gh + `gnomonitoring
oss | katana | GovDAO validator-ejection daemon | ` + gh + `katana
oss | gno-validator-tools | Validators & sentries as code | ` + gh + `gno-validator-tools
oss | gov-research-wiki | The governance research lab | ` + gh + `gov-research-wiki
oss | peerdev | The Peer Dev channel, in the open | ` + gh + `peerdev
oss | validator-diagnostics | The validator fire-drill portal | ` + gh + `validator-diagnostics
oss | gno-onboarding-bot | Validator onboarding, on Discord | ` + gh + `gno-onboarding-bot
oss | gno-govdao-activity-parser | GovDAO voter activity & test env | ` + gh + `gno-govdao-activity-parser
`},

	{"products", `
product | Memba | Organizations OS for gno.land | https://memba.samourai.app
product | Zenao | Event ticketing & community coordination | https://zenao.io
product | gnolove | Who builds gno.land, ranked | https://gnolove.world
product | Visio | Free video meetings, no account | https://visio.samourai.app
product | Greffon | Self-host sovereign apps in one click | https://greffon.io
product | Reportz | The digital commons, live from GitHub | https://reportz.dev
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

	{"films", `
film | The Underground Sistine Chapel | Feature documentary · 2021 | ` + yt + `fsRFHmdiyGE
film | Hashiriya | Documentary · 2025 | ` + yt + `OqMTmSEbqqY
film | Soy Yo | Documentary · 2025 | ` + yt + `fWE2fpZuDEM
film | Mañana cuesta más | Documentary · 2026 | ` + yt + `PEAR7l8dGEk
film | Community Networks | Documentary · 2024 | ` + yt + `JuHVteEhNzo
film | I'm Just a Lost Guy | Short film · 2025 | ` + yt + `84RgQxdI3n8
`},
}
