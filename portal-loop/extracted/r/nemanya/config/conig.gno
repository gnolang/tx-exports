package config

import (
	"errors"
	"std"
)

var (
	main   std.Address
	backup std.Address
)

func init() {
	main = "g1u5svs9gnr3s24vf22ff4uy0u35uh4gtg3c33s8"
}

func Address() std.Address {
	return main
}

func Backup() std.Address {
	return backup
}

func SetAddress(a std.Address) error {
	if !a.IsValid() {
		return errors.New("config: invalid address")
	}

	if err := checkAuthorized(); err != nil {
		return err
	}

	main = a
	return nil
}

func SetBackup(a std.Address) error {
	if !a.IsValid() {
		return errors.New("config: invalid address")
	}

	if err := checkAuthorized(); err != nil {
		return err
	}

	main = a
	return nil
}

func checkAuthorized() error {
	caller := std.PrevRealm().Addr()
	if caller != main || caller != backup {
		return errors.New("config: unauthorized")
	}

	return nil
}

func AssertAuthorized() {
	caller := std.PrevRealm().Addr()
	if caller != main || caller != backup {
		panic("config: unauthorized")
	}
}
