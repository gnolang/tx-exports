package ironclad

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestScoringAndGrades(t *testing.T) {
	uassert.Equal(t, 100, ComputeScore(0, 0, 0, 0))
	uassert.Equal(t, "A+", ComputeGrade(100, 0, 0))

	s1 := ComputeScore(0, 0, 1, 1) // 92
	uassert.Equal(t, 92, s1)
	uassert.Equal(t, "A", ComputeGrade(s1, 0, 0))

	s2 := ComputeScore(0, 1, 0, 0) // 85
	uassert.Equal(t, 85, s2)
	uassert.Equal(t, "B", ComputeGrade(s2, 0, 1))

	// Even high score with a critical finding caps grade at D
	s3 := ComputeScore(1, 0, 0, 0) // 70
	uassert.Equal(t, 70, s3)
	uassert.Equal(t, "D", ComputeGrade(s3, 1, 0))

	uassert.Equal(t, 0, ComputeScore(5, 5, 5, 5))
	uassert.Equal(t, "F", ComputeGrade(0, 5, 5))
}

func TestValidatePkgPath(t *testing.T) {
	uassert.True(t, ValidatePkgPath("gno.land/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/tollgate"))
	uassert.True(t, ValidatePkgPath("gno.land/p/nt/avl/v0"))
	uassert.False(t, ValidatePkgPath("gno.land/r/../evil"))
	uassert.False(t, ValidatePkgPath("http://evil.com/r/x"))
	uassert.False(t, ValidatePkgPath("gno.land/r/a/"))
}

func TestCanonicalAttestationDigest(t *testing.T) {
	srcHash := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	repHash := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	d := AttestationDigest(
		"onyx-1",
		"gno.land/r/demo/vault",
		srcHash,
		repHash,
		"ironclad-1.0.0",
		0, 0, 1, 2, 0,
	)
	uassert.True(t, IsValidHexDigest(d))
	uassert.True(t, VerifyAttestationDigest(
		d, "onyx-1", "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 0, 0, 1, 2, 0,
	))
	uassert.False(t, VerifyAttestationDigest(
		d, "onyx-1", "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 1, 0, 1, 2, 0,
	))
	t.Log("IRONCLAD_GNO_DIGEST=" + d)
	uassert.True(t, len(Taxonomy()) >= 14)
}
