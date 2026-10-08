package contest

import "gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"

// configDigest is the canonical digest of the project configuration that
// produced this realm.
const configDigest = "sha256:3331f81eb7b7680d3f2131ae50dfbbcd0080a281fbc35f2c6523a810d0c08bd5"

// Descriptor identifies this app's recipe and components.
func Descriptor() core.AppDescriptor {
	return core.AppDescriptor{
		Recipe:        recipeID,
		RecipeVersion: recipeVersion,
		Components: []string{
			"ballots@1.0.0",
			"core@1.0.0",
			"forms@1.0.0",
			"membership@1.0.0",
			"policies@1.0.0",
			"render@1.0.0",
		},
		ConfigDigest:      configDigest,
		ViewSchemaVersion: core.ViewSchemaVersion,
		Bindings:          []string{"membership.read/v1=" + pkgPath},
	}
}
