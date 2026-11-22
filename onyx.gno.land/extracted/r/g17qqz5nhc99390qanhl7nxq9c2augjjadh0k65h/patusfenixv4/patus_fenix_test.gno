
package patusfenixv4

import (
    "testing"
    "strings"

    "gno.land/p/nt/testutils/v0"
    "gno.land/p/nt/urequire/v0"
)

func TestPatusFenixMint(cur realm, t *testing.T) {
    // Verificar que inicialmente no hay NFTs.
    urequire.Equal(t, int64(0), TotalSupply())

    // Simular la llamada desde una wallet de prueba.
    alice := testutils.TestAddress("alice")

    result := func() string {
        return MintTest(cross(cur))
    }()

    urequire.Equal(t, "Patus Fenix minted successfully", result)

    // Comprobar que existe exactamente un NFT.
    urequire.Equal(t, int64(1), TotalSupply())

    // Comprobar que el NFT tiene un propietario.
owner := OwnerOf()
urequire.True(t, owner != "")
urequire.True(t, owner != "g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqd8f3t")

    // Comprobar la URL de los metadatos.
    urequire.Equal(
        t,
        "https://patusworld.com/patus-testnet/Patus-fenix.webp",
        TokenURI("1"),
    )


    // Comprobar los metadatos del NFT.
    data, err := TokenMetadata("1")
    urequire.True(t, err == nil)
    urequire.True(t, strings.Contains(data, "Patus Phoenix - Test NFT"))
    urequire.True(t, strings.Contains(data, "No commercial value."))
    urequire.True(t, strings.Contains(data, "Patus-fenix.webp"))
    urequire.True(t, strings.Contains(data, `"traitType": "Body"`))
    urequire.True(t, strings.Contains(data, `"traitType": "Background"`))
    urequire.True(t, strings.Contains(data, `"traitType": "Tech"`))
    urequire.True(t, strings.Contains(data, `"traitType": "System"`))
    urequire.True(t, strings.Contains(data, `"traitType": "Error"`))

    // Consultar un NFT inexistente debe devolver un error.
    _, invalidErr := TokenMetadata("999")
    urequire.True(t, invalidErr != nil)

    // Un segundo mint no debe crear otro NFT.
    second := MintTest(cross(cur))
    urequire.Equal(t, "Patus Fenix has already been minted", second)
    urequire.Equal(t, int64(1), TotalSupply())

    // Verificar que la dirección de prueba es válida.
    urequire.True(t, alice.IsValid())
}
