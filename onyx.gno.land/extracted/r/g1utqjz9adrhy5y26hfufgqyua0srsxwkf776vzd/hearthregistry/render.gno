package hearthregistry

// Render shows the parameter store for gnoweb.

import (
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	out := "# HearthRegistry — demo execution target\n\n"
	out += "A tiny on-chain parameter store. Only the HearthCouncil DAO\n"
	out += "realm can change values (after a proposal passes, queues, and\n"
	out += "executes). Anyone can read.\n\n"
	out += "## Parameters\n\n"
	for _, k := range Keys() {
		out += ufmt.Sprintf("- %s: %s\n", k, GetParam(k))
	}
	out += "\nTry it: pass a DAO proposal with action `set_param` and args\n"
	out += "`key=value` — after the timelock, the value above changes.\n"
	return out
}
