package clubpoll

import "gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"

// configDigest is the canonical digest of the project configuration that
// produced this realm.
const configDigest = "sha256:71e3b6329d3673ad99b14ca709473ade630b2ec3c8ee265c10ecdc2978d6ec2b"

// Descriptor identifies this app's recipe and components.
func Descriptor() core.AppDescriptor {
	return core.AppDescriptor{
		Recipe:        recipeID,
		RecipeVersion: recipeVersion,
		Components: []string{
			"ballots@1.0.0",
			"core@1.0.0",
			"membership@1.0.0",
			"policies@1.0.0",
			"render@1.0.0",
		},
		ConfigDigest:      configDigest,
		ViewSchemaVersion: core.ViewSchemaVersion,
		Bindings:          []string{"membership.read/v1=" + pkgPath},
	}
}
