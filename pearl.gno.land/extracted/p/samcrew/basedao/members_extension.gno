package basedao

import "gno.land/p/samcrew/daokit"

type MembersViewExtension interface {
	IsMember(memberId string) bool
}

// The extension registry key. It names this package, so it has to match the
// path this package is published at — third-party lookups are pinned to this
// literal once published, and it named gno.land/p/demo/basedao, which does not
// exist.
const MembersViewExtensionPath = "gno.land/p/samcrew/basedao.MembersView"

// The realm is threaded because daokit.DAO.Extension takes one. This extension
// is public, so any realm may fetch it and the realm is not checked — pass your
// own cur.
func MustGetMembersViewExtension(dao daokit.DAO, rlm realm) MembersViewExtension {
	ext := dao.Extension(MembersViewExtensionPath, rlm)
	if ext == nil {
		panic("no such extension: " + MembersViewExtensionPath)
	}
	val, ok := ext.(MembersViewExtension)
	if !ok {
		panic("extension does not conform to interface: " + MembersViewExtensionPath)
	}
	return val
}

type membersViewExtension struct {
	getStore  func() *MembersStore
	queryPath string
}

func (m *membersViewExtension) IsMember(memberId string) bool {
	return m.getStore().IsMember(memberId)
}

var _ MembersViewExtension = (*membersViewExtension)(nil)

func (m *membersViewExtension) Info() daokit.ExtensionInfo {
	return daokit.ExtensionInfo{
		Path:      MembersViewExtensionPath,
		Version:   "1",
		QueryPath: m.queryPath,
	}
}
