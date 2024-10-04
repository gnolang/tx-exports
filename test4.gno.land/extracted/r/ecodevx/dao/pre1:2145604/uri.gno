package gnome

import (
	"std"
	"strings"

	"gno.land/p/demo/ufmt"

	gnome "gno.land/p/ecodevx/dao"
)

func makeRealmURL(renderPath string) string {
	var (
		sub string
		id  = std.GetChainID()
	)

	// Sub domain prefix for testnets
	if strings.HasPrefix(id, "test") {
		sub = id + "."
	}

	url := "https://" + sub + std.CurrentRealm().PkgPath()
	if renderPath != "" {
		url += ":" + renderPath
	}
	return url
}

func makeRealmPath(renderPath string) string {
	return strings.TrimPrefix(std.CurrentRealm().PkgPath(), "gno.land") + ":" + renderPath
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
