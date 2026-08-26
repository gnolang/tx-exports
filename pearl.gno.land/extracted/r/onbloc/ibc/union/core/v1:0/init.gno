package core

import (
	core "gno.land/r/onbloc/ibc/union/core"
)

func init(cur realm) {
	core.RegisterImpl(cross(cur), func(s core.IStore) core.ICore {
		return NewCoreV1(s)
	})
}
