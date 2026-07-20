// Package gnomcp is the on-chain presentation page for the gnomcp project,
// an MCP server plus agent skill that connects gno.land to AI coding agents.
// Static content only: no state, no crossing functions.
package gnomcp

const page = `# gnomcp

**gnomcp** is an MCP server and agent skill that connects gno.land to your
coding agent: Claude Code, Claude Desktop, Cursor, Gemini CLI, OpenCode, or
anything else that speaks MCP. Once it's installed you talk to your agent in
plain language, and it reads realms, checks accounts, deploys code, and sends
transactions on a real chain.

> [!WARNING]
> Work in progress, unaudited. Writes only work on dev and testnet chains.
> Mainnet and betanet stay read-only.

## Why gno.land works well for agents

Everything on gno.land is readable Go-like source stored on chain, with
transparent state. An agent can read a realm the same way it reads any
codebase. What was missing was a safe way to let it act. gnomcp adds that
part: live chain queries, a testnet key of its own to sign with, and a
bundled **gno skill** that teaches it where Gno differs from Go, so it stops
guessing from Go or Solidity habits.

<gno-columns>
## Explore

Ask what realms exist, what they render, and what an account holds. Live
reads work on any chain, including this one.

<gno-columns-sep />

## Build

Describe what you want. The agent writes the realm, tests it locally, does a
security pass, deploys to testnet, and calls it to prove it works.

<gno-columns-sep />

## Audit

Ask for a security review of any deployed realm. Read-only, works on mainnet
too, findings backed by quoted source.
</gno-columns>

## Try it

Once gnomcp is installed, tell your agent:

> *"Deploy a check-in board: anyone can check in, it records their address,
> and reading it back lists everyone so far. Then check in yourself."*

New to gno.land? Ask it to teach you instead, it will walk you through a
hands-on tour.

## Install

One command installs the server binary and the agent skills:

` + "```sh\ncurl -fsSL https://raw.githubusercontent.com/gnoverse/gno-mcp/main/scripts/install.sh | sh\n```" + `

This pipes a script from the internet into your shell, so read it first:
[scripts/install.sh](https://github.com/gnoverse/gno-mcp/blob/main/scripts/install.sh).
Then restart your editor or agent.

## Safety

- **Your keys stay in gnokey.** The agent signs with its own throwaway
  testnet key. Acting as you always goes through an authorization you sign
  yourself, on your own machine.
- **No signing on real-funds chains.** The mainnet write path does not exist
  in the code.
- **Chain output is data, not instructions.** Everything read from the chain
  is wrapped as untrusted content, so a malicious realm can't steer the
  agent.
- **Every write is logged**, and the log names which account signed.

## Links

- Source: [github.com/gnoverse/gno-mcp](https://github.com/gnoverse/gno-mcp)
- Docs: [tool catalog](https://github.com/gnoverse/gno-mcp/blob/main/docs/tools.md) and
  [security posture](https://github.com/gnoverse/gno-mcp/blob/main/docs/security.md)
- License: Apache-2.0
`

// Render serves the same presentation page for every path.
func Render(_ string) string {
	return page
}
