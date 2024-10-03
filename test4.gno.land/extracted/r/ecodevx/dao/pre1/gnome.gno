package gnome

import (
	"strings"

	gnome "gno.land/p/ecodevx/dao"
)

// Names of the initial DAOs.
const (
	nameCouncilDAO = "council"
	nameMainDAO    = "main"
)

// Member roles.
const (
	RoleAdmin  gnome.Role = "admin"
	RoleEcoDev gnome.Role = "eco-dev"
	RoleDev    gnome.Role = "dev"
	RoleRealm  gnome.Role = "realm"
)

// The "Gno.me" DAO defines an initial root DAO with a single sub DAO, where the root is
// the council DAO and the child is the main DAO. Council DAO members are hard coded and
// can't be modified. Main DAO members can be modified anytime though a modify DAO members
// proposals.
//
// The main DAO must have a minimum of three members at all time to be able to apply 2/3s
// voting majority criteria required for some proposal types allowed for the main DAO.
//
// Sub DAOs can be created though sub DAO add proposals but its members can't be modified
// once the sub DAO is created. Sub DAOs must be dismissed though a proposal and a new sub
// DAO must be created if its members must be modified.
var gnomeDAO = gnome.MustNew(
	nameCouncilDAO,
	"Council",
	gnome.WithManifest("Gnomes are thinking"),
	gnome.AssignAsSuperCouncil(),
	gnome.WithMembers(
		gnome.NewMember("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun", RoleDev),
		gnome.NewMember("g125t352u4pmdrr57emc4pe04y40sknr5ztng5mt", RoleDev),
		gnome.NewMember("g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5", RoleEcoDev),
	),
	gnome.WithSubDAO(
		gnome.MustNew(
			nameMainDAO,
			"Main",
			gnome.WithManifest("Gnomes are building"),
			gnome.WithMembers(
				gnome.NewMember("g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun", RoleDev),
				gnome.NewMember("g125t352u4pmdrr57emc4pe04y40sknr5ztng5mt", RoleDev),
				gnome.NewMember("g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5", RoleEcoDev),
			),
		),
	),
)

func mustGetDAO(path string) *gnome.DAO {
	if strings.TrimSpace(path) == "" {
		panic("DAO path is empty")
	}

	dao, found := daos.GetByPath(path)
	if !found {
		panic("DAO not found")
	}
	return dao
}
