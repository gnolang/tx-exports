package flag

import (
	"chain"
	"testing"
)

func TestPlayerUser(t *testing.T) {
	user := testing.MakeRealm(ash, "", testing.OriginRealm())
	got, err := Player(user)
	if err != nil || got != ash {
		t.Fatalf("Player(user) = %s, %v", got, err)
	}
}

func TestPlayerNamespace(t *testing.T) {
	path := "gno.land/r/" + string(briar) + "/solutions/rack"
	code := testing.MakeRealm(chain.PackageAddress(path), path, testing.OriginRealm())
	got, err := Player(code)
	if err != nil || got != briar {
		t.Fatalf("Player(code) = %s, %v", got, err)
	}
}

func TestPlayerRejectsNamedNamespace(t *testing.T) {
	for _, path := range []string{"gno.land/r/moul/home", "gno.land/r/x", "gno.land/p/" + string(ash) + "/lib"} {
		code := testing.MakeRealm(chain.PackageAddress(path), path, testing.OriginRealm())
		if _, err := Player(code); err != ErrNoPlayer {
			t.Errorf("Player(%q) err = %v, want ErrNoPlayer", path, err)
		}
	}
}

func TestMustPlayerPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("MustPlayer should panic for an unknown namespace")
		}
	}()
	path := "gno.land/r/moul/home"
	MustPlayer(testing.MakeRealm(chain.PackageAddress(path), path, testing.OriginRealm()))
}
