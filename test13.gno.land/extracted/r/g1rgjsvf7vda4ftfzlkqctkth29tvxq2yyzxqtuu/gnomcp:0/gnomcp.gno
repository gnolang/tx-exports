// Package gnomcp is the on-chain presentation page for the gnomcp project:
// an MCP server + agent skill that connects gno.land to AI coding agents.
// Static content only — no state, no crossing functions.
package gnomcp

const page = `# gnomcp — gno.land for AI agents

**gnomcp** is an MCP server + agent skill connecting gno.land to any
MCP-capable coding agent — Claude Code,
Claude Desktop, Cursor, Gemini CLI, OpenCode, and more. Your agent reads
realms, evaluates expressions, inspects accounts, and simulates or broadcasts
transactions — grounded in real chain queries, never guessed.

> [!WARNING]
> Work in progress — unaudited and pre-release. Writes are confined to dev and
> testnet chains; mainnet and betanet are read-only by design.

## Why gno.land + AI

Everything on gno.land is readable Go-like source, interpreted on-chain, with
fully transparent state. That makes it unusually legible to an AI agent: it
can read a realm the way it reads any codebase. gnomcp closes the loop — the
bundled **gno skill** teaches the agent interrealm semantics, idiomatic
patterns, and the security model, so it writes correct Gno instead of
pattern-matching from Go or Solidity.

<gno-columns>
## Explore

Ask which realms exist, what they render, and what an account holds — live
reads on any chain, including this one.

<gno-columns-sep />

## Build

Describe the behavior you want; the agent writes the realm, tests it locally,
runs a security pass, deploys to testnet, and proves it with a real call.

<gno-columns-sep />

## Audit

Ask for a security review of any deployed realm — read-only, works on mainnet
too, with findings backed by quoted source.
</gno-columns>

## Try it

Say this to your agent once gnomcp is installed:

> *"Deploy a check-in board at gno.land/r/test/checkin: anyone can check in,
> it records their address, and reading it back lists everyone so far. Then
> check in yourself."*

Or start from zero — ask it to teach you gno.land and it gives you a
hands-on tour.

## Install

One command installs the server binary and the agent skills:

` + "```sh\ncurl -fsSL https://raw.githubusercontent.com/gnoverse/gno-mcp/main/scripts/install.sh | sh\n```" + `

It pipes a script from the internet into your shell — read it first:
[scripts/install.sh](https://github.com/gnoverse/gno-mcp/blob/main/scripts/install.sh).
Then restart your editor or agent.

## Safety, structurally

- **Your keys never enter the process** — the agent signs with its own
  disposable testnet key; acting as you is always authorized by you, via your
  own gnokey.
- **No signing on real-funds chains** — the mainnet write path does not exist
  in the code.
- **Chain output can't hijack the agent** — every chain-derived byte is
  wrapped as untrusted content.
- **Every write is logged** — an append-only audit trail names the signer.

## Links

- Source: [github.com/gnoverse/gno-mcp](https://github.com/gnoverse/gno-mcp)
- Docs: [tool catalog](https://github.com/gnoverse/gno-mcp/blob/main/docs/tools.md) ·
  [security posture](https://github.com/gnoverse/gno-mcp/blob/main/docs/security.md)
- License: Apache-2.0
`

// Render serves the same presentation page for every path.
func Render(_ string) string {
	return page
}
