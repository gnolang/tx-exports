package gnome

import (
	"std"
	"strings"

	"gno.land/p/demo/ufmt"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

func makeRealmURL(renderPath string) string {
	var sub string
	if id := std.GetChainID(); strings.HasPrefix(id, "test") {
		// Sub domain prefix for testnets
		sub = id + "."
	}

	url := "https://" + sub + std.CurrentRealm().PkgPath()
	if renderPath != "" {
		url += ":" + renderPath
	}
	return url
}

func makeRealmPath(renderPath string) string {
	path := gnome.CutRealmDomain(std.CurrentRealm().PkgPath())
	if renderPath != "" {
		path += ":" + renderPath
	}
	return path
}

func makeGnoStudioConnectURL(functionName string) string {
	return ufmt.Sprintf(
		"https://gno.studio/connect/view/%s?network=%s&tab=functions#%s",
		std.CurrentRealm().PkgPath(),
		std.GetChainID(),
		functionName,
	)
}

func makeDAOURI(daoPath string, isRelative bool) string {
	renderPath := "dao/" + daoPath
	if isRelative {
		return makeRealmPath(renderPath)
	}
	return makeRealmURL(renderPath)
}

func makeProposalURI(proposalID gnome.ID, isRelative bool) string {
	renderPath := "proposal/" + proposalID.String()
	if isRelative {
		return makeRealmPath(renderPath)
	}
	return makeRealmURL(renderPath)
}

func makeProposalsURI(daoPath string, isRelative bool) string {
	renderPath := "proposals/" + daoPath + ":page=1"
	if isRelative {
		return makeRealmPath(renderPath)
	}
	return makeRealmURL(renderPath)
}
