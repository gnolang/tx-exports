package perun

func Render(path string) string {
	return `
# ⚡ PERUN

PERUN is a decentralized token built on Gno.land.

---

## Token information

**Name:** PERUN  
**Symbol:** PERUN  
**Network:** Gno.land  
**Token standard:** GRC20  

PERUN is an experimental community token created within the Gno.land ecosystem.

The project is designed to remain simple and decentralized, with minimal dependence on centralized infrastructure.

---

## Contract

PERUN was created using the Gno.land GRC20 token factory.

Mainnet token path:

` + "`gno.land/r/demo/defi/grc20factory.PERUN`" + `

---

## Ecosystem

PERUN can interact with decentralized applications running on Gno.land, including decentralized exchanges such as GnoSwap.

[Gno.land](https://gno.land)

[GnoSwap](https://gnoswap.io)

---

## Philosophy

PERUN is intended to be a decentralized experiment.

The project does not depend on a central website, company or organization and makes no promises regarding future development or value.

---

*PERUN — built on Gno.land*
`
}
