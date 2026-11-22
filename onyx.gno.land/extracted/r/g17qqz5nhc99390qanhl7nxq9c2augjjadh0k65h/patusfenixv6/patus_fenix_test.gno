
package patusfenixv6

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

    urequire.Equal(t, "Patus Unclassified Files minted successfully", result)

    // Comprobar que existe exactamente un NFT.
    urequire.Equal(t, int64(1), TotalSupply())

    // Comprobar que el NFT tiene un propietario.
owner := OwnerOf()
urequire.True(t, owner != "")
urequire.True(t, owner != "g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqd8f3t")

    // Comprobar la URL de los metadatos.
    urequire.Equal(
        t,
        "https://arweave.net/VF1LH2dL7FKIRm3U90Tgdu8IHPDso6fg0xZteYEhE3c",
        TokenURI("1"),
    )


    // Comprobar los metadatos del NFT.
    data, err := TokenMetadata("1")
    urequire.True(t, err == nil)
    urequire.True(t, strings.Contains(data, "Patus Unclassified Files"))
    urequire.True(t, strings.Contains(data, "No commercial value."))
    urequire.True(t, strings.Contains(data, "https://arweave.net/VF1LH2dL7FKIRm3U90Tgdu8IHPDso6fg0xZteYEhE3c"))
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
    urequire.Equal(t, "Patus Unclassified Files has already been minted", second)
    urequire.Equal(t, int64(1), TotalSupply())


    // Comprobar los permisos de transferencia.
    currentOwner, err := collection.OwnerOf("1")
    urequire.True(t, err == nil)

    bob := testutils.TestAddress("bob")
    stranger := testutils.TestAddress("stranger")

    // Un tercero no autorizado no puede transferir el NFT.
    err = ledger.TransferFrom(stranger, currentOwner, bob, "1")
    urequire.True(t, err != nil)
    urequire.Equal(t, currentOwner.String(), OwnerOf())

    // El propietario puede transferir su NFT.
    TransferFrom(cross(cur), currentOwner, bob, "1")
    urequire.Equal(t, bob.String(), OwnerOf())

    // La transferencia no modifica el supply.
    urequire.Equal(t, int64(1), TotalSupply())

    // Los metadatos se conservan tras la transferencia.
    urequire.Equal(t, "https://arweave.net/VF1LH2dL7FKIRm3U90Tgdu8IHPDso6fg0xZteYEhE3c", TokenURI("1"))

    afterMetadata, afterErr := TokenMetadata("1")
    urequire.True(t, afterErr == nil)
    urequire.Equal(t, data, afterMetadata)

    // Verificar que la dirección de prueba es válida.
    urequire.True(t, alice.IsValid())
}
