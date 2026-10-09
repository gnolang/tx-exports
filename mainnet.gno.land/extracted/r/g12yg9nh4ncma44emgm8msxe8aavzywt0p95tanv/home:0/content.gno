package home

// Default content, written once by init. Everything here stays editable
// after deploy: SetProfile, SetBadges and SetPage replace it.

func defaultProfile() profileData {
	return profileData{name: "6h057", tagline: "I turn coffee into code."}
}

func defaultBadges() []badge {
	return []badge{
		{label: "Samouraï Coop", value: "member", url: "https://www.samourai.world"},
		{label: "Greffon", value: "builder", url: "https://www.greffon.io/"},
		{label: "ino.cash", value: "builder", url: "https://ino.cash/"},
		{label: "ETHDenver 2023", value: "winner", url: "https://ethereumdenver.medium.com/ethdenver-2023-track-and-bounty-winners-1d9cbeda1dc8", row: true},
		{label: "GitHub", value: "omarsy", url: "https://github.com/omarsy"},
		{label: "X", value: "@omarsysy", url: "https://x.com/omarsysy"},
	}
}

// defaultHome needs base, so init sets base first.
func defaultHome() string {
	return `:banner:

:badges:

:now:

<gno-columns>
## About

I work on the GnoVM: gas metering, determinism and correctness fixes. I also build [Greffon](https://www.greffon.io/) and [ino.cash](https://ino.cash/).

<gno-columns-sep>

## Work on Gno

Contributor to gnolang/gno since April 2024, mostly in the GnoVM. I've also contributed to Go and React.

[Highlights](` + base + `:work)
</gno-columns>

:posts:

:waves: :tip: :sign:
`
}

const defaultWork = `## Work on Gno

Contributor to gnolang/gno since April 2024 ([my merged PRs](https://github.com/gnolang/gno/pulls?q=is%3Apr+author%3Aomarsy+is%3Amerged)). Some highlights:

| PR | What it did |
| --- | --- |
| [#3185](https://github.com/gnolang/gno/pull/3185) | Software floating point, so floats are deterministic |
| [#4546](https://github.com/gnolang/gno/pull/4546) | Gas for memory allocation |
| [#4705](https://github.com/gnolang/gno/pull/4705) | Gas for print and println CPU time |
| [#2145](https://github.com/gnolang/gno/pull/2145) | Stack traces in panic messages |
| [#5902](https://github.com/gnolang/gno/pull/5902) | Lazy loading of package file blocks |
| [#6025](https://github.com/gnolang/gno/pull/6025) | Type-check only production files at AddPackage |

## Beyond Gno

### Greffon

[Greffon](https://www.greffon.io/) turns any machine into a greffer: a VPS, a Mac mini, a Windows PC, a Raspberry Pi or a NAS that runs your own apps. You pick from 24 open-source apps (Plausible, Ghost, Nextcloud, Vaultwarden and more), and Greffon handles TLS, routing and config. Your data stays on your hardware, and self-hosting is free with no feature gating.

I work across the stack:

- [greffer](https://github.com/greffon/greffer): the worker node that deploys each app with Docker behind TLS (Python, FastAPI; AGPL v3).
- The manager: the control plane and its web app (AGPL v3, source published at launch).
- [greffon-catalog](https://github.com/greffon/greffon-catalog): the app catalog and the CI that validates it (Apache 2.0).

### ino.cash

[ino.cash](https://ino.cash/) is an OTC desk for the CFA franc zone. People buy and sell USDT, USDC, BTC and ETH against CFA francs (XOF) with Wave, Orange Money or Pi (BCEAO), in all 8 UEMOA countries, at a rate locked for 10 minutes. Delivery takes under 10 minutes on average, on TRON, Solana, Base, Aptos, Ethereum or Bitcoin, and a white-label API for businesses is in private beta.

### Okay Relay

[Okay Relay](https://web.archive.org/web/20250126155102/https://app.buidlbox.io/projects/okay-relay) is cross-chain message relaying as a service, built on Wormhole, so dApps don't have to run their own relayers. It won $4,000 in Moonbeam's "Use a GMP Protocol to Remotely Call a Contract" bounty at [ETHDenver 2023](https://ethereumdenver.medium.com/ethdenver-2023-track-and-bounty-winners-1d9cbeda1dc8).

### Also

- Go runtime: [softfloat64 add/sub fix](https://github.com/golang/go/commit/a2fd613c3e3c1b1441047372230169f41419b773) (June 2026). The same fix landed in Gno as [#5818](https://github.com/gnolang/gno/pull/5818).
- React: 4 merged PRs to React DevTools in 2020. Iframe support in the browser extension ([#19827](https://github.com/react/react/pull/19827), [#19854](https://github.com/react/react/pull/19854)), symbols shown as state keys ([#19786](https://github.com/react/react/pull/19786)), and a crash fix when inspecting ` + "`document.all`" + ` ([#19619](https://github.com/react/react/pull/19619)).
- All in Bits: wallet UI for dither.chat (3 merged PRs, 2025).
`

const defaultBlog = `## Blog

:blog:
`

const defaultGuestbook = `## Guestbook

Leave a line. One entry per address.

:guestbook:
`
