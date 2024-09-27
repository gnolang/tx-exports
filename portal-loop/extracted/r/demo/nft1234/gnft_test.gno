package gnft

import (
	"std"
	"testing"

	pusers "gno.land/p/demo/users"
)

func TestGNFT(t *testing.T) {
	// admin := pusers.AddressOrName("g1y3uyaa63sjxvah2cx3c2usavwvx97kl8m2v7ye")
	adminRealm := std.NewUserRealm(admin)
	std.TestSetRealm(adminRealm)

	adminUser := pusers.AddressOrName(admin)

	// mint to admin
	Mint(adminUser, "1")
	Mint(adminUser, "2")
	Mint(adminUser, "3")
	Mint(adminUser, "4")
	Mint(adminUser, "5")
	Mint(adminUser, "6")
	Mint(adminUser, "7")
	Mint(adminUser, "8")
	Mint(adminUser, "9")
	Mint(adminUser, "10")
}

func TestGetTokenURI(t *testing.T) {
	url := GetTokenURI("1")
	if url != NFT_IMAGE_01 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_01, url)
	}

	url = GetTokenURI("2")
	if url != NFT_IMAGE_02 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_02, url)
	}

	url = GetTokenURI("3")
	if url != NFT_IMAGE_03 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_03, url)
	}

	url = GetTokenURI("4")
	if url != NFT_IMAGE_04 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_04, url)
	}

	url = GetTokenURI("5")
	if url != NFT_IMAGE_05 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_05, url)
	}

	url = GetTokenURI("6")
	if url != NFT_IMAGE_03 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_03, url)
	}

	url = GetTokenURI("7")
	if url != NFT_IMAGE_01 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_01, url)
	}

	url = GetTokenURI("7")
	if url != NFT_IMAGE_01 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_01, url)
	}

	url = GetTokenURI("8")
	if url != NFT_IMAGE_04 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_04, url)
	}

	url = GetTokenURI("9")
	if url != NFT_IMAGE_03 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_03, url)
	}

	url = GetTokenURI("10")
	if url != NFT_IMAGE_05 {
		t.Errorf("expected %s, got %s", NFT_IMAGE_05, url)
	}

	// PANIC
	shouldPanicWithMsg(
		t,
		func() {
			GetTokenURI("11")
		},
		"invalid token id",
	)

}

func shouldPanicWithMsg(t *testing.T, f func(), msg string) {
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("The code did not panic")
		} else {
			if r != msg {
				t.Errorf("excepted panic(%v), got(%v)", msg, r)
			}
		}
	}()
	f()
}
