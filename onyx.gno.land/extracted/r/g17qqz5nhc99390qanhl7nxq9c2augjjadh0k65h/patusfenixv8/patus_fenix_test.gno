package patusfenixv8

import (
    "strings"
    "testing"
    "gno.land/p/nt/grc721/v0"

    "gno.land/p/nt/testutils/v0"
    "gno.land/p/nt/urequire/v0"
)

func TestPatusWorldV8(cur realm, t *testing.T) {
    urequire.Equal(t, int64(0), TotalSupply())

    images := []string{
        "https://patusworld.com/patus-testnet/Patus-fenix.webp",
        "https://patusworld.com/patus-testnet/ferpect.webp",
        "https://patusworld.com/patus-testnet/pretending-to-be.webp",
    }

    names := []string{
        "Patus Fenix",
        "Patus Ferpect",
        "Patus Pretending to Be",
    }

    ids := []string{"1", "2", "3"}

    // Acunar los tres NFT y comprobar cada uno.
    for i := 0; i < 3; i++ {
        result := MintTest(cross(cur))
        urequire.Equal(t, "Patus World V8 NFT minted successfully", result)
        urequire.Equal(t, int64(i+1), TotalSupply())

        tokenID := ids[i]

        urequire.True(t, OwnerOf(tokenID) != "")
        urequire.Equal(t, images[i], TokenURI(tokenID))

        data, err := TokenMetadata(grc721.TokenID(tokenID))
        urequire.True(t, err == nil)
        urequire.True(t, strings.Contains(data, names[i]))
        urequire.True(t, strings.Contains(data, images[i]))

        for _, trait := range []string{
            "Body", "Background", "Tech", "System", "Error",
        } {
            urequire.True(t, strings.Contains(data, `"traitType": "`+trait+`"`))
        }
    }

    // Las tres imagenes deben ser diferentes.
    urequire.True(t, TokenURI("1") != TokenURI("2"))
    urequire.True(t, TokenURI("2") != TokenURI("3"))
    urequire.True(t, TokenURI("1") != TokenURI("3"))

    // No se puede acunar un cuarto NFT.
    result := MintTest(cross(cur))
    urequire.Equal(t, "All three Patus World V8 NFTs have been minted", result)
    urequire.Equal(t, int64(3), TotalSupply())

    // Un NFT inexistente no debe tener metadatos.
    _, err := TokenMetadata("999")
    urequire.True(t, err != nil)
    urequire.Equal(t, "", TokenURI("999"))
    urequire.Equal(t, "", OwnerOf("999"))

    // Verificar que un tercero no puede transferir el NFT #2.
    originalOwner, err := collection.OwnerOf("2")
    urequire.True(t, err == nil)

    bob := testutils.TestAddress("bob")
    stranger := testutils.TestAddress("stranger")

    err = ledger.TransferFrom(stranger, originalOwner, bob, "2")
    urequire.True(t, err != nil)
    urequire.Equal(t, originalOwner.String(), OwnerOf("2"))

    // Guardar los metadatos antes de la transferencia.
    beforeMetadata, err := TokenMetadata("2")
    urequire.True(t, err == nil)
    beforeURI := TokenURI("2")

    // Transferir el NFT #2 con el propietario autorizado.
    TransferFrom(cross(cur), originalOwner, bob, "2")

    urequire.Equal(t, bob.String(), OwnerOf("2"))
    urequire.Equal(t, int64(3), TotalSupply())
    urequire.Equal(t, beforeURI, TokenURI("2"))

    afterMetadata, err := TokenMetadata("2")
    urequire.True(t, err == nil)
    urequire.Equal(t, beforeMetadata, afterMetadata)

    // Los otros dos NFT conservan su propietario.
    urequire.Equal(t, originalOwner.String(), OwnerOf("1"))
    urequire.Equal(t, originalOwner.String(), OwnerOf("3"))
}
