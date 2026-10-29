package mirror

import (
	"errors"

	"gno.land/p/demo/avl"
)

var ErrRealmNotFound = errors.New("realm not found")

type (
	RenderFn func(path string) string

	Mirror struct {
		realms *avl.Tree // string(realm URI) -> RenderFn
	}
)

func New() Mirror {
	return Mirror{realms: avl.NewTree()}
}

func (m *Mirror) Register(realm string, fn RenderFn) {
	m.realms.Set(realm, fn)
}

func (m Mirror) IsRegistered(realm string) bool {
	return m.realms.Has(realm)
}

func (m Mirror) Render(realm, path string) (string, error) {
	v, found := m.realms.Get(realm)
	if !found {
		return "", ErrRealmNotFound
	}

	render := v.(RenderFn)
	return render(path), nil
}

func (m Mirror) MustRender(realm, path string) string {
	s, err := m.Render(realm, path)
	if err != nil {
		panic(err)
	}
	return s
}
