package soup

import "testing"

// Gas probes: one step on one normal sentence. Run one at a time with
//   gno test -run TestGasX -print-runtime-metrics .
const gasSentence = "Otobüs yine gelmedi, yarım saattir duraktayım, ayaklarım dondu."

func gasLong() string {
	s := ""
	for len(s) < 500 {
		s += gasSentence + " "
	}
	return s[:500]
}

func TestGasEmpty(t *testing.T)  {}
func TestGasSecret(t *testing.T) { Secret(gasSentence) }
func TestGasToxic(t *testing.T)  { Toxic(gasSentence) }
func TestGasClean(t *testing.T)  { Clean(gasSentence) }
func TestGasFlavor(t *testing.T) { Flavor(gasSentence) }
func TestGasCheck(t *testing.T)  { Check(gasSentence) }
func TestGasCheck500(t *testing.T) { Check(gasLong()) }
