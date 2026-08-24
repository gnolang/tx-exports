package dependency

import "gno.land/p/nt/ufmt/v0"

func Render(_ string) string {
	return ufmt.Sprintf("# Dependency Chain\n\nImported external package: gno.land/p/nt/ufmt/v0\n")
}
