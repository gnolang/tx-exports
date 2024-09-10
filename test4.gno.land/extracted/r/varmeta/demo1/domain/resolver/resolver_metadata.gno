package resolver

import (
	"std"
	"time"

	"gno.land/p/varmeta/demo1/domain"
)

// Metadata wrapper
func MetadataWrapper(owner std.Address, name string, ttl time.Duration) domain.Metadata {
	crrTime := time.Now()
	expTime := crrTime.Add(ttl)
	return domain.NewMetadata("", name, "", "", crrTime, expTime, []domain.Trait{})
}
