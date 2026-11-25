package patusworld404_onyx_v2

import (
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
    "gno.land/p/nt/grc721/royalty/v0"
    "chain/banker"
    "chain"
    "time"
    "gno.land/p/nt/avl/v0"
    "gno.land/p/nt/testutils/v0"
    "strconv"
    "strings"
    "testing"

    "gno.land/p/nt/urequire/v0"
)

func TestCatalogAndPricing(cur realm, t *testing.T) {
    urequire.Equal(t, 44, MaxSupply)
    urequire.Equal(t, 36, PaidSupply)

    for i := 1; i <= 44; i++ {
        id := strconv.Itoa(i)
        uri, data := catalogEntry(id)

        urequire.True(t, strings.HasPrefix(uri, "https://arweave.net/"))
        urequire.True(t, strings.Contains(data, uri))
        urequire.True(t, strings.Contains(data, `"attributes"`))
        urequire.True(t, strings.Contains(data, `"Rarity"`))
    }

    uri, data := catalogEntry("45")
    urequire.Equal(t, "", uri)
    urequire.Equal(t, "", data)

    urequire.Equal(t, int64(44000), PriceAt(0))
    urequire.Equal(t, int64(44000), PriceAt(3))
    urequire.Equal(t, int64(96000), PriceAt(4))
    urequire.Equal(t, int64(96000), PriceAt(11))
    urequire.Equal(t, int64(144000), PriceAt(12))
    urequire.Equal(t, int64(144000), PriceAt(27))
    urequire.Equal(t, int64(404000), PriceAt(28))
    urequire.Equal(t, int64(404000), PriceAt(35))
}

func TestInitialState(cur realm, t *testing.T) {
    urequire.Equal(t, int64(0), TotalSupply())
    urequire.Equal(t, 0, PaidMinted())
    urequire.Equal(t, 0, FreeMinted())
    urequire.Equal(t, 0, CreatorMinted())
    urequire.Equal(t, 44, RemainingSupply())
}

func TestCreatorMint(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_creator")

    admin = wallet
    creator = wallet
    testing.SetRealm(testing.NewUserRealm(wallet))

    MintCreator(cross(cur))
    MintCreator(cross(cur))

    urequire.Equal(t, int64(2), TotalSupply())
    urequire.Equal(t, 2, CreatorMinted())
    urequire.Equal(t, 0, PaidMinted())
    urequire.Equal(t, 0, FreeMinted())
    urequire.Equal(t, 42, RemainingSupply())
    urequire.Equal(t, wallet.String(), OwnerOf("1"))
    urequire.Equal(t, wallet.String(), OwnerOf("2"))
    urequire.True(t, strings.HasPrefix(TokenURI("1"), "https://arweave.net/"))
}


func TestWhitelistManagement(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_admin")
    user1 := testutils.TestAddress("patus_user_1")
    user2 := testutils.TestAddress("patus_user_2")

    admin = wallet
    whitelist = avl.Tree{}
    testing.SetRealm(testing.NewUserRealm(wallet))

    urequire.Equal(t, 0, WhitelistCount())

    SetWhitelist(cross(cur), user1, true)
    SetWhitelist(cross(cur), user2, true)

    urequire.Equal(t, 2, WhitelistCount())
    urequire.True(t, IsWhitelisted(user1))
    urequire.True(t, IsWhitelisted(user2))

    SetWhitelist(cross(cur), user1, true)
    urequire.Equal(t, 2, WhitelistCount())

    SetWhitelist(cross(cur), user1, false)

    urequire.Equal(t, 1, WhitelistCount())
    urequire.False(t, IsWhitelisted(user1))
    urequire.True(t, IsWhitelisted(user2))
}

func TestWhitelistCapacity(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_admin")
    admin = wallet
    whitelist = avl.Tree{}
    testing.SetRealm(testing.NewUserRealm(wallet))

    for i := 0; i < FreeSupply; i++ {
        user := testutils.TestAddress("patus_wl_" + strconv.Itoa(i))
        SetWhitelist(cross(cur), user, true)
        urequire.True(t, IsWhitelisted(user))
    }

    urequire.Equal(t, 6, WhitelistCount())
}

func TestFreeClaimAvailability(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_admin")
    user := testutils.TestAddress("patus_free_user")

    admin = wallet
    creator = wallet
    whitelist = avl.Tree{}
    opened = false
    paused = false
    openedAt = 0
    pauseSeconds = 0
    freeMinted = 0
    paidMinted = 0
    claimed = avl.Tree{}

    testing.SetRealm(testing.NewUserRealm(wallet))

    urequire.False(t, FreeClaimAvailable(user))

    SetWhitelist(cross(cur), user, true)
    urequire.True(t, IsWhitelisted(user))
    urequire.False(t, FreeClaimAvailable(user))

    treasury = testutils.TestAddress("patus_treasury")
    recovery = testutils.TestAddress("patus_recovery")

    OpenMint(cross(cur))

    urequire.True(t, FreeClaimAvailable(user))
    urequire.Equal(t, int64(0), QuoteMint(user, 1))
    urequire.Equal(t, int64(44000), QuoteMint(user, 2))
}

func TestFreeMint(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_free_minter")

    admin = testutils.TestAddress("patus_admin")
    creator = admin
    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0

    whitelist.Set(wallet.String(), true)

    testing.SetRealm(testing.NewUserRealm(wallet))

    before := TotalSupply()
    beforeFree := FreeMinted()
    beforePaid := PaidMinted()

    Mint(cross(cur), 1, 0)

    urequire.Equal(t, before+1, TotalSupply())
    urequire.Equal(t, beforeFree+1, FreeMinted())
    urequire.Equal(t, beforePaid, PaidMinted())
    urequire.True(t, HasClaimed(wallet))
    urequire.Equal(t, wallet.String(), OwnerOf(strconv.FormatInt(before+1, 10)))
}

func TestFreeClaimOnlyOnce(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_one_free")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    whitelist.Set(wallet.String(), true)
    testing.SetRealm(testing.NewUserRealm(wallet))

    urequire.True(t, FreeClaimAvailable(wallet))

    Mint(cross(cur), 1, 0)

    urequire.True(t, HasClaimed(wallet))
    urequire.False(t, FreeClaimAvailable(wallet))
    urequire.Equal(t, int64(44000), QuoteMint(wallet, 1))
}

func TestPaidMintQuotes(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_paid_user")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    urequire.False(t, IsWhitelisted(wallet))
    urequire.False(t, FreeClaimAvailable(wallet))

    urequire.Equal(t, int64(44000), QuoteMint(wallet, 1))
    urequire.Equal(t, int64(272000), QuoteMint(wallet, 5))
    urequire.Equal(t, int64(752000), QuoteMint(wallet, 10))

    paidMinted = 3

    urequire.Equal(t, int64(44000), QuoteMint(wallet, 1))
    urequire.Equal(t, int64(140000), QuoteMint(wallet, 2))
    urequire.Equal(t, int64(236000), QuoteMint(wallet, 3))
}

func TestPaidMint(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_paid_minter")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    treasury = testutils.TestAddress("patus_treasury")

    testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 44000}})

    testing.SetRealm(testing.NewUserRealm(wallet))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 44000}})

    before := TotalSupply()

    readonly := banker.NewReadonlyBanker()
    treasuryBefore := readonly.GetCoins(treasury).AmountOf("ugnot")

    Mint(cross(cur), 1, 44000)

    treasuryAfter := readonly.GetCoins(treasury).AmountOf("ugnot")
    contractAfter := readonly.GetCoins(chain.PackageAddress("gno.land/r/g1cfxu4vd25vc2xm6y8lx3v63cvm8gmxvswwmcux/patusworld404_onyx_v2")).AmountOf("ugnot")

    urequire.Equal(t, treasuryBefore+int64(44000), treasuryAfter)
    urequire.Equal(t, int64(0), contractAfter)

    urequire.Equal(t, before+1, TotalSupply())
    urequire.Equal(t, 1, PaidMinted())
    urequire.Equal(t, 0, FreeMinted())
    urequire.Equal(t, 1, PaidMintedBy(wallet))
    urequire.Equal(t, wallet.String(), OwnerOf(strconv.FormatInt(before+1, 10)))
}

func TestPaidWalletLifetimeLimit(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_wallet_limit")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    urequire.Equal(t, int64(752000), QuoteMint(wallet, 10))

    paidByWallet.Set(wallet.String(), 6)

    urequire.Equal(t, 6, PaidMintedBy(wallet))
    urequire.Equal(t, int64(176000), QuoteMint(wallet, 4))

    paidByWallet.Set(wallet.String(), 10)

    urequire.Equal(t, 10, PaidMintedBy(wallet))
}

func TestPaidMintMultiplePurchases(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_buyer_multi")
    treasury = testutils.TestAddress("patus_treas_multi")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    readonly := banker.NewReadonlyBanker()
    treasuryBefore := readonly.GetCoins(treasury).AmountOf("ugnot")
    supplyBefore := TotalSupply()

    testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 752000}})
    testing.SetRealm(testing.NewUserRealm(wallet))

    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 368000}})
    Mint(cross(cur), 6, 368000)

    urequire.Equal(t, 6, PaidMintedBy(wallet))
    urequire.Equal(t, 6, PaidMinted())

    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 384000}})
    Mint(cross(cur), 4, 384000)

    urequire.Equal(t, 10, PaidMintedBy(wallet))
    urequire.Equal(t, 10, PaidMinted())
    urequire.Equal(t, supplyBefore+10, TotalSupply())
    urequire.Equal(t, treasuryBefore+int64(752000), readonly.GetCoins(treasury).AmountOf("ugnot"))
    urequire.Equal(t, int64(0), readonly.GetCoins(chain.PackageAddress("gno.land/r/g1cfxu4vd25vc2xm6y8lx3v63cvm8gmxvswwmcux/patusworld404_onyx_v2")).AmountOf("ugnot"))
}

func TestCreatorSupplyReservation(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_supply_test")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    originalTotal := totalMinted
    originalCreator := creatorMinted

    totalMinted = 33
    creatorMinted = 0

    urequire.Equal(t, 11, RemainingSupply())
    urequire.Equal(t, int64(656000), QuoteMint(wallet, 9))

    totalMinted = 34
    creatorMinted = 1

    urequire.Equal(t, 10, RemainingSupply())
    urequire.Equal(t, int64(656000), QuoteMint(wallet, 9))

    totalMinted = 34
    creatorMinted = 2

    urequire.Equal(t, 10, RemainingSupply())
    urequire.Equal(t, int64(752000), QuoteMint(wallet, 10))

    totalMinted = originalTotal
    creatorMinted = originalCreator
}

func TestWhitelistExpirationConditions(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_expiry_user")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    pauseSeconds = 0
    freeMinted = 0

    whitelist.Set(wallet.String(), true)

    // Han pasado 32 minutos, pero quedan NFTs de pago.
    openedAt = time.Now().Unix() - 32*60
    paidMinted = 35

    urequire.True(t, FreeClaimAvailable(wallet))

    // Se han vendido los 36 NFTs, pero aún no han pasado 30 minutos.
    openedAt = time.Now().Unix() - 28*60
    paidMinted = 36

    urequire.True(t, FreeClaimAvailable(wallet))

    // Ambas condiciones cumplidas: termina el derecho gratuito.
    openedAt = time.Now().Unix() - 32*60
    paidMinted = 36

    urequire.False(t, FreeClaimAvailable(wallet))
}

func TestWhitelistPauseTime(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_pause_user")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    freeMinted = 0
    paidMinted = PaidSupply

    whitelist.Set(wallet.String(), true)

    // 32 minutos desde la apertura, con 6 minutos de pausa acumulada.
    openedAt = time.Now().Unix() - 32*60
    pauseSeconds = 6*60

    urequire.True(t, FreeClaimAvailable(wallet))

    // Sin tiempo de pausa, el derecho ya habría caducado.
    pauseSeconds = 0

    urequire.False(t, FreeClaimAvailable(wallet))

    // Restablecer el estado temporal.
    pauseSeconds = 0
}

func TestPauseAndResumeMint(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("patus_pause_admin")
    user := testutils.TestAddress("patus_pause_claim")

    admin = wallet
    whitelist = avl.Tree{}
    claimed = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix() - 60
    pausedAt = 0
    pauseSeconds = 0
    freeMinted = 0
    paidMinted = 0

    whitelist.Set(user.String(), true)

    testing.SetRealm(testing.NewUserRealm(wallet))

    urequire.True(t, FreeClaimAvailable(user))

    PauseMint(cross(cur))

    urequire.True(t, paused)
    urequire.False(t, FreeClaimAvailable(user))

    ResumeMint(cross(cur))

    urequire.False(t, paused)
    urequire.Equal(t, int64(0), pausedAt)
    urequire.True(t, FreeClaimAvailable(user))
}

func TestAdminRecovery(cur realm, t *testing.T) {
    oldAdmin := testutils.TestAddress("patus_old_admin")
    recoveryWallet := testutils.TestAddress("patus_recovery")
    newAdmin := testutils.TestAddress("patus_new_admin")

    admin = oldAdmin
    recovery = recoveryWallet

    testing.SetRealm(testing.NewUserRealm(recoveryWallet))

    ReplaceAdmin(cross(cur), newAdmin)

    urequire.Equal(t, newAdmin.String(), admin.String())
    urequire.Equal(t, recoveryWallet.String(), recovery.String())
}

func TestAdminTransfer(cur realm, t *testing.T) {
    oldAdmin := testutils.TestAddress("patus_admin_old")
    newAdmin := testutils.TestAddress("patus_admin_new")
    recoveryWallet := testutils.TestAddress("patus_admin_backup")

    admin = oldAdmin
    recovery = recoveryWallet
    opened = true
    paused = false
    openedAt = time.Now().Unix() - 60
    pausedAt = 0
    pauseSeconds = 0

    testing.SetRealm(testing.NewUserRealm(oldAdmin))

    ReplaceAdmin(cross(cur), newAdmin)

    urequire.Equal(t, newAdmin.String(), admin.String())

    testing.SetRealm(testing.NewUserRealm(newAdmin))

    PauseMint(cross(cur))
    urequire.True(t, paused)

    ResumeMint(cross(cur))
    urequire.False(t, paused)

    urequire.Equal(t, recoveryWallet.String(), recovery.String())
}

func TestConfigureAndOpenMint(cur realm, t *testing.T) {
    adminWallet := testutils.TestAddress("patus_config_admin")
    treasuryWallet := testutils.TestAddress("patus_config_treas")
    recoveryWallet := testutils.TestAddress("patus_config_recov")
    creatorWallet := testutils.TestAddress("patus_config_creat")

    admin = adminWallet
    opened = false
    paused = false
    openedAt = 0

    testing.SetRealm(testing.NewUserRealm(adminWallet))

    Configure(cross(cur), treasuryWallet, recoveryWallet, creatorWallet)

    urequire.Equal(t, treasuryWallet.String(), treasury.String())
    urequire.Equal(t, recoveryWallet.String(), recovery.String())
    urequire.Equal(t, creatorWallet.String(), creator.String())

    OpenMint(cross(cur))

    urequire.True(t, opened)
    urequire.False(t, paused)
    urequire.True(t, openedAt > 0)
}

func TestNFTTransfer(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_creator")
    recipient := testutils.TestAddress("patus_receiver")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    supplyBefore := TotalSupply()

    testing.SetRealm(testing.NewUserRealm(owner))

    TransferFrom(cross(cur), owner, recipient, "1")

    urequire.Equal(t, recipient.String(), OwnerOf("1"))
    urequire.Equal(t, supplyBefore, TotalSupply())
}

func TestNFTTransferPreservesMetadata(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_creator")
    recipient := testutils.TestAddress("patus_meta_receiver")

    urequire.Equal(t, owner.String(), OwnerOf("2"))

    uriBefore := TokenURI("2")
    supplyBefore := TotalSupply()

    urequire.True(t, strings.HasPrefix(uriBefore, "https://arweave.net/"))

    testing.SetRealm(testing.NewUserRealm(owner))

    TransferFrom(cross(cur), owner, recipient, "2")

    urequire.Equal(t, recipient.String(), OwnerOf("2"))
    urequire.Equal(t, uriBefore, TokenURI("2"))
    urequire.Equal(t, supplyBefore, TotalSupply())
}

func TestNFTSecondTransfer(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_receiver")
    recipient := testutils.TestAddress("patus_third_owner")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    uriBefore := TokenURI("1")
    supplyBefore := TotalSupply()

    testing.SetRealm(testing.NewUserRealm(owner))

    TransferFrom(cross(cur), owner, recipient, "1")

    urequire.Equal(t, recipient.String(), OwnerOf("1"))
    urequire.Equal(t, uriBefore, TokenURI("1"))
    urequire.Equal(t, supplyBefore, TotalSupply())
}

func TestUnauthorizedNFTTransfer(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_third_owner")
    attacker := testutils.TestAddress("patus_attacker")
    recipient := testutils.TestAddress("patus_stolen_dest")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    uriBefore := TokenURI("1")
    supplyBefore := TotalSupply()

    err := ledger.TransferFrom(attacker, owner, recipient, grc721.TokenID("1"))

    urequire.ErrorIs(t, err, grc721.ErrCallerIsNotOwnerOrApproved)

    urequire.Equal(t, owner.String(), OwnerOf("1"))
    urequire.Equal(t, uriBefore, TokenURI("1"))
    urequire.Equal(t, supplyBefore, TotalSupply())
}

func TestUnauthorizedAdminTakeover(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("secure_admin")
    recoveryWallet := testutils.TestAddress("secure_recovery")
    attacker := testutils.TestAddress("secure_attacker")

    admin = legitimateAdmin
    recovery = recoveryWallet

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "not authorized", func() {
        ReplaceAdmin(cross(cur), attacker)
    })

    urequire.Equal(t, legitimateAdmin.String(), admin.String())
    urequire.Equal(t, recoveryWallet.String(), recovery.String())
}

func TestUnauthorizedPauseMint(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("pause_admin")
    attacker := testutils.TestAddress("pause_attacker")

    admin = legitimateAdmin
    opened = true
    paused = false
    openedAt = time.Now().Unix() - 60
    pausedAt = 0

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "admin only", func() {
        PauseMint(cross(cur))
    })

    urequire.False(t, paused)
    urequire.Equal(t, int64(0), pausedAt)
    urequire.Equal(t, legitimateAdmin.String(), admin.String())
}

func TestUnauthorizedResumeMint(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("resume_admin")
    attacker := testutils.TestAddress("resume_attacker")

    admin = legitimateAdmin
    opened = true
    paused = true
    openedAt = time.Now().Unix() - 120
    pausedAt = time.Now().Unix() - 60

    pauseBefore := pauseSeconds
    pausedAtBefore := pausedAt

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "admin only", func() {
        ResumeMint(cross(cur))
    })

    urequire.True(t, paused)
    urequire.Equal(t, pausedAtBefore, pausedAt)
    urequire.Equal(t, pauseBefore, pauseSeconds)
    urequire.Equal(t, legitimateAdmin.String(), admin.String())
}

func TestUnauthorizedWhitelistModification(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("wl_admin")
    attacker := testutils.TestAddress("wl_attacker")
    target := testutils.TestAddress("wl_target")

    admin = legitimateAdmin
    opened = false
    whitelist = avl.Tree{}

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "admin only", func() {
        SetWhitelist(cross(cur), target, true)
    })

    urequire.False(t, IsWhitelisted(target))
    urequire.Equal(t, 0, WhitelistCount())
    urequire.Equal(t, legitimateAdmin.String(), admin.String())
}

func TestUnauthorizedConfiguration(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("cfg_admin")
    attacker := testutils.TestAddress("cfg_attacker")

    originalTreasury := testutils.TestAddress("cfg_treasury")
    originalRecovery := testutils.TestAddress("cfg_recovery")
    originalCreator := testutils.TestAddress("cfg_creator")

    admin = legitimateAdmin
    treasury = originalTreasury
    recovery = originalRecovery
    creator = originalCreator
    opened = false

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "admin only", func() {
        Configure(cross(cur), attacker, attacker, attacker)
    })

    urequire.Equal(t, originalTreasury.String(), treasury.String())
    urequire.Equal(t, originalRecovery.String(), recovery.String())
    urequire.Equal(t, originalCreator.String(), creator.String())
    urequire.Equal(t, legitimateAdmin.String(), admin.String())
}

func TestUnauthorizedOpenMint(cur realm, t *testing.T) {
    legitimateAdmin := testutils.TestAddress("open_admin")
    attacker := testutils.TestAddress("open_attacker")

    admin = legitimateAdmin
    treasury = testutils.TestAddress("open_treasury")
    recovery = testutils.TestAddress("open_recovery")
    opened = false
    openedAt = 0

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "admin only", func() {
        OpenMint(cross(cur))
    })

    urequire.False(t, opened)
    urequire.Equal(t, int64(0), openedAt)
    urequire.Equal(t, legitimateAdmin.String(), admin.String())
}

func TestUnauthorizedCreatorMint(cur realm, t *testing.T) {
    legitimateCreator := testutils.TestAddress("mint_creator")
    attacker := testutils.TestAddress("mint_attacker")

    creator = legitimateCreator
    opened = true
    paused = false

    mintedBefore := creatorMinted
    supplyBefore := TotalSupply()

    testing.SetRealm(testing.NewUserRealm(attacker))

    urequire.AbortsWithMessage(t, cur, "creator only", func() {
        MintCreator(cross(cur))
    })

    urequire.Equal(t, mintedBefore, creatorMinted)
    urequire.Equal(t, supplyBefore, TotalSupply())
    urequire.Equal(t, legitimateCreator.String(), creator.String())
}

func TestCreatorCannotMintThirdNFT(cur realm, t *testing.T) {
    legitimateCreator := testutils.TestAddress("limit_creator")

    creator = legitimateCreator
    creatorMinted = 2
    opened = true
    paused = false

    supplyBefore := TotalSupply()
    totalBefore := totalMinted

    testing.SetRealm(testing.NewUserRealm(legitimateCreator))

    urequire.AbortsWithMessage(t, cur, "creator reserve exhausted", func() {
        MintCreator(cross(cur))
    })

    urequire.Equal(t, 2, creatorMinted)
    urequire.Equal(t, totalBefore, totalMinted)
    urequire.Equal(t, supplyBefore, TotalSupply())
}

func TestWhitelistSupplyReservation(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("wl_reserve_user")
    buyer := testutils.TestAddress("wl_reserve_buyer")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix() - 28*60
    pauseSeconds = 0

    originalTotal := totalMinted
    originalPaid := paidMinted
    originalFree := freeMinted
    originalCreator := creatorMinted

    totalMinted = 36
    paidMinted = 36
    freeMinted = 0
    creatorMinted = 0

    whitelist.Set(wallet.String(), true)

    urequire.Equal(t, 8, RemainingSupply())
    urequire.True(t, FreeClaimAvailable(wallet))
    urequire.Equal(t, int64(0), QuoteMint(wallet, 1))

    urequire.PanicsWithMessage(t, cur, "paid limit exceeded", func() {
        QuoteMint(buyer, 1)
    })

    totalMinted = originalTotal
    paidMinted = originalPaid
    freeMinted = originalFree
    creatorMinted = originalCreator
}

func TestRejectIncorrectPayment(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("wrong_payment")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    supplyBefore := TotalSupply()
    totalBefore := totalMinted

    testing.SetRealm(testing.NewUserRealm(wallet))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 43000}})

    urequire.AbortsWithMessage(t, cur, "send exact quote in ugnot", func() {
        Mint(cross(cur), 1, 44000)
    })

    // Reject overpayment.
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 45000}})
    urequire.AbortsWithMessage(t, cur, "send exact quote in ugnot", func() {
        Mint(cross(cur), 1, 44000)
    })

    // Reject incorrect denomination.
    testing.SetOriginSend(chain.Coins{{Denom: "utest", Amount: 44000}})
    urequire.AbortsWithMessage(t, cur, "send exact quote in ugnot", func() {
        Mint(cross(cur), 1, 44000)
    })

    // Reject missing payment.
    testing.SetOriginSend(chain.Coins{})
    urequire.AbortsWithMessage(t, cur, "send exact quote in ugnot", func() {
        Mint(cross(cur), 1, 44000)
    })

    urequire.Equal(t, supplyBefore, TotalSupply())
    urequire.Equal(t, totalBefore, totalMinted)
    urequire.Equal(t, 0, PaidMinted())
    urequire.Equal(t, 0, PaidMintedBy(wallet))
}

func TestRejectUnauthorizedPrice(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("price_ceiling")

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    paidMinted = 0
    freeMinted = 0

    supplyBefore := TotalSupply()
    totalBefore := totalMinted

    testing.SetRealm(testing.NewUserRealm(wallet))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 44000}})

    urequire.AbortsWithMessage(t, cur, "price changed: exceeds authorization", func() {
        Mint(cross(cur), 1, 40000)
    })

    urequire.Equal(t, supplyBefore, TotalSupply())
    urequire.Equal(t, totalBefore, totalMinted)
    urequire.Equal(t, 0, PaidMinted())
    urequire.Equal(t, 0, PaidMintedBy(wallet))
}

func TestNFTIndividualApproval(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_third_owner")
    operator := testutils.TestAddress("patus_operator")
    recipient := testutils.TestAddress("patus_receiver2")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    testing.SetRealm(testing.NewUserRealm(owner))
    Approve(cross(cur), operator, "1")

    approved, err := GetApproved("1")
    urequire.NoError(t, err)
    urequire.Equal(t, operator, approved)

    testing.SetRealm(testing.NewUserRealm(operator))
    TransferFrom(cross(cur), owner, recipient, "1")

    urequire.Equal(t, recipient.String(), OwnerOf("1"))
}

func TestNFTOperatorApprovalAndRevocation(cur realm, t *testing.T) {
    operator := testutils.TestAddress("patus_market_op")

    // NFT 1 belongs to patus_receiver2 after the previous test.
    owner := testutils.TestAddress("patus_receiver2")
    urequire.Equal(t, owner.String(), OwnerOf("1"))

    testing.SetRealm(testing.NewUserRealm(owner))
    SetApprovalForAll(cross(cur), operator, true)

    urequire.True(t, IsApprovedForAll(owner, operator))

    SetApprovalForAll(cross(cur), operator, false)

    urequire.False(t, IsApprovedForAll(owner, operator))

    err := ledger.TransferFrom(operator, owner, testutils.TestAddress("patus_dest"), grc721.TokenID("1"))
    urequire.ErrorIs(t, err, grc721.ErrCallerIsNotOwnerOrApproved)

    urequire.Equal(t, owner.String(), OwnerOf("1"))
}

func TestNFTOperatorAuthorizedTransfer(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_receiver2")
    operator := testutils.TestAddress("patus_market_op")
    recipient := testutils.TestAddress("patus_market_dest")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    testing.SetRealm(testing.NewUserRealm(owner))
    SetApprovalForAll(cross(cur), operator, true)

    urequire.True(t, IsApprovedForAll(owner, operator))

    testing.SetRealm(testing.NewUserRealm(operator))
    TransferFrom(cross(cur), owner, recipient, "1")

    urequire.Equal(t, recipient.String(), OwnerOf("1"))
    urequire.False(t, IsApprovedForAll(recipient, operator))
}

func TestNFTApprovalClearedAfterTransfer(cur realm, t *testing.T) {
    owner := testutils.TestAddress("patus_market_dest")
    operator := testutils.TestAddress("patus_clear_op")
    recipient := testutils.TestAddress("patus_clear_dest")

    urequire.Equal(t, owner.String(), OwnerOf("1"))

    testing.SetRealm(testing.NewUserRealm(owner))
    Approve(cross(cur), operator, "1")

    approved, err := GetApproved("1")
    urequire.NoError(t, err)
    urequire.Equal(t, operator, approved)

    TransferFrom(cross(cur), owner, recipient, "1")

    urequire.Equal(t, recipient.String(), OwnerOf("1"))

    _, err = GetApproved("1")
    urequire.ErrorIs(t, err, grc721.ErrTokenIdNotApproved)

    err = ledger.TransferFrom(operator, recipient, owner, grc721.TokenID("1"))
    urequire.ErrorIs(t, err, grc721.ErrCallerIsNotOwnerOrApproved)
}

func TestReleasedWhitelistQuotes(cur realm, t *testing.T) {
    buyer := testutils.TestAddress("release_buyer")

    oldOpened, oldPaused := opened, paused
    oldOpenedAt, oldPauseSeconds := openedAt, pauseSeconds
    oldPaid, oldFree, oldReleased := paidMinted, freeMinted, releasedMinted
    oldTotal, oldCreator := totalMinted, creatorMinted

    defer func() {
        opened, paused = oldOpened, oldPaused
        openedAt, pauseSeconds = oldOpenedAt, oldPauseSeconds
        paidMinted, freeMinted, releasedMinted = oldPaid, oldFree, oldReleased
        totalMinted, creatorMinted = oldTotal, oldCreator
    }()

    opened = true
    paused = false
    pauseSeconds = 0
    openedAt = time.Now().Unix() - 32*60
    paidMinted = 36
    freeMinted = 4
    releasedMinted = 0
    totalMinted = 40
    creatorMinted = 0

    urequire.True(t, WhitelistReleased())
    urequire.Equal(t, 2, ReleasedRemaining())
    urequire.Equal(t, int64(404000), QuoteMint(buyer, 1))
    urequire.Equal(t, int64(808000), QuoteMint(buyer, 2))

    releasedMinted = 1
    totalMinted = 41

    urequire.Equal(t, 1, ReleasedRemaining())
    urequire.Equal(t, int64(404000), QuoteMint(buyer, 1))

    urequire.PanicsWithMessage(t, cur, "creator reserve protected", func() {
        QuoteMint(buyer, 2)
    })

    openedAt = time.Now().Unix() - 28*60
    urequire.False(t, WhitelistReleased())
    urequire.Equal(t, 0, ReleasedRemaining())

    openedAt = time.Now().Unix() - 32*60
    paused = true
    urequire.False(t, WhitelistReleased())
}

func TestReleasedWhitelistPaidMint(cur realm, t *testing.T) {
    buyer := testutils.TestAddress("release_paid")
    receiver := testutils.TestAddress("release_treasury")

    oldOpened, oldPaused := opened, paused
    oldOpenedAt, oldPauseSeconds := openedAt, pauseSeconds
    oldPaid, oldFree, oldReleased := paidMinted, freeMinted, releasedMinted
    oldTotal, oldCreator := totalMinted, creatorMinted
    oldTreasury := treasury

    defer func() {
        opened, paused = oldOpened, oldPaused
        openedAt, pauseSeconds = oldOpenedAt, oldPauseSeconds
        paidMinted, freeMinted, releasedMinted = oldPaid, oldFree, oldReleased
        totalMinted, creatorMinted = oldTotal, oldCreator
        treasury = oldTreasury
    }()

    opened = true
    paused = false
    openedAt = time.Now().Unix() - 32*60
    pauseSeconds = 0
    paidMinted = PaidSupply
    freeMinted = 0
    releasedMinted = 0
    creatorMinted = 0
    treasury = receiver

    // Keep the next minted ID unique in the existing test ledger.
    totalMinted = int(TotalSupply())

    before := TotalSupply()
    urequire.True(t, WhitelistReleased())
    urequire.Equal(t, int64(404000), QuoteMint(buyer, 1))

    readonly := banker.NewReadonlyBanker()
    treasuryBefore := readonly.GetCoins(receiver).AmountOf("ugnot")

    testing.IssueCoins(cur.Address(), chain.Coins{{Denom: "ugnot", Amount: 404000}})
    testing.SetRealm(testing.NewUserRealm(buyer))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 404000}})

    Mint(cross(cur), 1, 404000)

    urequire.Equal(t, before+1, TotalSupply())
    urequire.Equal(t, PaidSupply, PaidMinted())
    urequire.Equal(t, 1, ReleasedMinted())
    urequire.Equal(t, 1, PaidMintedBy(buyer))
    urequire.Equal(t, buyer.String(), OwnerOf(strconv.FormatInt(before+1, 10)))
    urequire.Equal(t, treasuryBefore+int64(404000), readonly.GetCoins(receiver).AmountOf("ugnot"))
}

func TestCreatorMintLastTwoNFTs(cur realm, t *testing.T) {
    wallet := testutils.TestAddress("last_two_creator")
    holder := testutils.TestAddress("last_two_holder")

    // Use a separate NFT ledger and restore the original test state.
    oldCollection, oldLedger := collection, ledger
    oldMeta, oldMetaLedger := nftMeta, metaLedger
    oldTotal, oldCreatorMinted := totalMinted, creatorMinted
    oldCreator, oldOpened, oldPaused := creator, opened, paused

    defer func() {
        collection, ledger = oldCollection, oldLedger
        nftMeta, metaLedger = oldMeta, oldMetaLedger
        totalMinted, creatorMinted = oldTotal, oldCreatorMinted
        creator, opened, paused = oldCreator, oldOpened, oldPaused
    }()

    collection, ledger = grc721.NewToken("ERROR 404: PATUS NOT FOUND", "PATUS404", 0, cur)
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
    totalMinted = 0

    urequire.Equal(t, int64(0), TotalSupply())

    creator = wallet
    creatorMinted = 0
    opened = true
    paused = false

    for i := 0; i < 42; i++ {
        mintOne(holder)
    }

    urequire.Equal(t, int64(42), TotalSupply())
    urequire.Equal(t, 2, RemainingSupply())
    urequire.Equal(t, holder.String(), OwnerOf("42"))

    testing.SetRealm(testing.NewUserRealm(wallet))
    testing.SetOriginSend(chain.Coins{})

    MintCreator(cross(cur))
    MintCreator(cross(cur))

    urequire.Equal(t, int64(44), TotalSupply())
    urequire.Equal(t, 2, CreatorMinted())
    urequire.Equal(t, 0, RemainingSupply())
    urequire.Equal(t, wallet.String(), OwnerOf("43"))
    urequire.Equal(t, wallet.String(), OwnerOf("44"))
    urequire.True(t, strings.HasPrefix(TokenURI("43"), "https://arweave.net/"))
    urequire.True(t, strings.HasPrefix(TokenURI("44"), "https://arweave.net/"))
}

func TestRoyaltyInfo(cur realm, t *testing.T) {
    receiver := testutils.TestAddress("royalty_treasury")
    recoveryWallet := testutils.TestAddress("royalty_recovery")
    creatorWallet := testutils.TestAddress("royalty_creator")

    oldAdmin := admin
    oldTreasury := treasury
    oldRecovery := recovery
    oldCreator := creator
    oldOpened := opened

    oldCollection, oldLedger := collection, ledger
    oldMeta, oldMetaLedger := nftMeta, metaLedger
    oldRoyalty, oldRoyaltyLedger := nftRoyalty, royaltyLedger

    defer func() {
        admin, treasury, recovery, creator = oldAdmin, oldTreasury, oldRecovery, oldCreator
        opened = oldOpened
        collection, ledger = oldCollection, oldLedger
        nftMeta, metaLedger = oldMeta, oldMetaLedger
        nftRoyalty, royaltyLedger = oldRoyalty, oldRoyaltyLedger
    }()

    collection, ledger = grc721.NewToken("ERROR 404: PATUS NOT FOUND", "PATUS404", 0, cur)
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
    nftRoyalty, royaltyLedger = royalty.NewRoyalty(ledger, 500)

    admin = testutils.TestAddress("royalty_admin")
    opened = false
    testing.SetRealm(testing.NewUserRealm(admin))

    Configure(cross(cur), receiver, recoveryWallet, creatorWallet)

    gotReceiver, amount, err := RoyaltyInfo("1", 200000000)
    urequire.NoError(t, err)
    urequire.Equal(t, receiver.String(), gotReceiver.String())
    urequire.Equal(t, int64(10000000), amount)

    gotReceiver, amount, err = RoyaltyInfo("1", 1000000)
    urequire.NoError(t, err)
    urequire.Equal(t, receiver.String(), gotReceiver.String())
    urequire.Equal(t, int64(50000), amount)

    _, _, err = RoyaltyInfo("1", -1)
    urequire.True(t, err != nil)
}

func TestCollectionPublicQueries(t *testing.T) {
    urequire.Equal(t, "ERROR 404: PATUS NOT FOUND", Name())
    urequire.Equal(t, "PATUS404", Symbol())

    wallet := testutils.TestAddress("query_wallet")
    balance, err := BalanceOf(wallet)
    urequire.NoError(t, err)
    urequire.Equal(t, int64(0), balance)

    _, err = BalanceOf(address(""))
    urequire.True(t, err != nil)
}

func TestConfigurationFrozenAfterAdminRecovery(cur realm, t *testing.T) {
    oldAdmin := admin
    oldRecovery := recovery
    oldTreasury := treasury
    oldCreator := creator
    oldOpened := opened

    defer func() {
        admin = oldAdmin
        recovery = oldRecovery
        treasury = oldTreasury
        creator = oldCreator
        opened = oldOpened
    }()

    admin = testutils.TestAddress("frozen_old_admin")
    recovery = testutils.TestAddress("frozen_recovery")
    treasury = testutils.TestAddress("frozen_treasury")
    creator = testutils.TestAddress("frozen_creator")
    opened = true

    originalRecovery := recovery
    originalTreasury := treasury
    originalCreator := creator

    newAdmin := testutils.TestAddress("frozen_new_admin")

    testing.SetRealm(testing.NewUserRealm(recovery))
    ReplaceAdmin(cross(cur), newAdmin)

    urequire.Equal(t, newAdmin.String(), admin.String())

    testing.SetRealm(testing.NewUserRealm(newAdmin))

    urequire.AbortsWithMessage(t, cur, "configuration frozen", func() {
        Configure(cross(cur), newAdmin, newAdmin, newAdmin)
    })

    urequire.Equal(t, originalTreasury.String(), treasury.String())
    urequire.Equal(t, originalRecovery.String(), recovery.String())
    urequire.Equal(t, originalCreator.String(), creator.String())
}

func TestAdminRejectsIndirectCall(cur realm, t *testing.T) {
    oldAdmin := admin
    oldOpened := opened

    defer func() {
        admin = oldAdmin
        opened = oldOpened
    }()

    admin = chain.PackageAddress("gno.land/r/tests/vm")
    opened = false

    testing.SetRealm(testing.NewCodeRealm("gno.land/r/tests/vm"))

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        OpenMint(cross(cur))
    })

    urequire.False(t, opened)
}

func TestReplaceAdminRejectsIndirectCall(cur realm, t *testing.T) {
    oldAdmin := admin
    oldRecovery := recovery

    defer func() {
        admin = oldAdmin
        recovery = oldRecovery
    }()

    codeWallet := chain.PackageAddress("gno.land/r/tests/vm")
    newAdmin := testutils.TestAddress("indirect_new_admin")

    admin = codeWallet
    recovery = testutils.TestAddress("indirect_recovery")

    testing.SetRealm(testing.NewCodeRealm("gno.land/r/tests/vm"))

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        ReplaceAdmin(cross(cur), newAdmin)
    })

    urequire.Equal(t, codeWallet.String(), admin.String())

    admin = testutils.TestAddress("indirect_admin")
    recovery = codeWallet

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        ReplaceAdmin(cross(cur), newAdmin)
    })

    urequire.Equal(t, codeWallet.String(), recovery.String())
    urequire.Equal(t, testutils.TestAddress("indirect_admin").String(), admin.String())
}

func TestMintRejectsIndirectCall(cur realm, t *testing.T) {
    supplyBefore := TotalSupply()
    totalBefore := totalMinted
    paidBefore := paidMinted
    freeBefore := freeMinted
    releasedBefore := releasedMinted

    testing.SetRealm(testing.NewCodeRealm("gno.land/r/tests/vm"))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 44000}})

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        Mint(cross(cur), 1, 44000)
    })

    urequire.Equal(t, supplyBefore, TotalSupply())
    urequire.Equal(t, totalBefore, totalMinted)
    urequire.Equal(t, paidBefore, paidMinted)
    urequire.Equal(t, freeBefore, freeMinted)
    urequire.Equal(t, releasedBefore, releasedMinted)
}

func TestChangeTreasuryAfterOpen(cur realm, t *testing.T) {
    oldAdmin, oldTreasury := admin, treasury
    oldOpened := opened
    oldCollection, oldLedger := collection, ledger
    oldRoyalty, oldRoyaltyLedger := nftRoyalty, royaltyLedger

    defer func() {
        admin, treasury = oldAdmin, oldTreasury
        opened = oldOpened
        collection, ledger = oldCollection, oldLedger
        nftRoyalty, royaltyLedger = oldRoyalty, oldRoyaltyLedger
    }()

    collection, ledger = grc721.NewToken("ERROR 404: PATUS NOT FOUND", "PATUS404", 0, cur)
    nftRoyalty, royaltyLedger = royalty.NewRoyalty(ledger, 500)

    admin = testutils.TestAddress("chg_treas_admin")
    treasury = testutils.TestAddress("chg_treas_old")
    newTreasury := testutils.TestAddress("chg_treas_new")
    opened = true

    testing.SetRealm(testing.NewUserRealm(admin))

    ChangeTreasury(cross(cur), newTreasury)

    urequire.Equal(t, newTreasury.String(), treasury.String())

    receiver, amount, err := RoyaltyInfo("1", 200000000)
    urequire.NoError(t, err)
    urequire.Equal(t, newTreasury.String(), receiver.String())
    urequire.Equal(t, int64(10000000), amount)
    urequire.True(t, opened)
}

func TestChangeRecoveryAfterOpen(cur realm, t *testing.T) {
    oldAdmin, oldRecovery := admin, recovery
    oldOpened := opened

    defer func() {
        admin, recovery = oldAdmin, oldRecovery
        opened = oldOpened
    }()

    admin = testutils.TestAddress("chg_recov_admin")
    recovery = testutils.TestAddress("chg_recov_old")
    previousRecovery := recovery
    newRecovery := testutils.TestAddress("chg_recov_new")
    newAdmin := testutils.TestAddress("chg_recov_new_admin")
    opened = true

    testing.SetRealm(testing.NewUserRealm(admin))

    ChangeRecovery(cross(cur), newRecovery)

    urequire.Equal(t, newRecovery.String(), recovery.String())

    testing.SetRealm(testing.NewUserRealm(previousRecovery))

    urequire.AbortsWithMessage(t, cur, "not authorized", func() {
        ReplaceAdmin(cross(cur), newAdmin)
    })

    testing.SetRealm(testing.NewUserRealm(newRecovery))

    ReplaceAdmin(cross(cur), newAdmin)

    urequire.Equal(t, newAdmin.String(), admin.String())
    urequire.Equal(t, newRecovery.String(), recovery.String())
    urequire.True(t, opened)
}

func TestWalletChangesSecurity(cur realm, t *testing.T) {
    oldAdmin, oldTreasury, oldRecovery := admin, treasury, recovery

    defer func() {
        admin, treasury, recovery = oldAdmin, oldTreasury, oldRecovery
    }()

    admin = testutils.TestAddress("wallet_admin")
    treasury = testutils.TestAddress("wallet_treasury")
    recovery = testutils.TestAddress("wallet_recovery")
    target := testutils.TestAddress("wallet_target")
    outsider := testutils.TestAddress("wallet_outsider")

    for _, caller := range []address{outsider, recovery, treasury} {
        testing.SetRealm(testing.NewUserRealm(caller))

        urequire.AbortsWithMessage(t, cur, "admin only", func() {
            ChangeTreasury(cross(cur), target)
        })

        urequire.AbortsWithMessage(t, cur, "admin only", func() {
            ChangeRecovery(cross(cur), target)
        })
    }

    testing.SetRealm(testing.NewUserRealm(admin))

    urequire.AbortsWithMessage(t, cur, "invalid address", func() {
        ChangeTreasury(cross(cur), address(""))
    })

    urequire.AbortsWithMessage(t, cur, "invalid address", func() {
        ChangeRecovery(cross(cur), address(""))
    })

    urequire.AbortsWithMessage(t, cur, "treasury must differ from admin", func() {
        ChangeTreasury(cross(cur), admin)
    })

    admin = chain.PackageAddress("gno.land/r/tests/vm")
    testing.SetRealm(testing.NewCodeRealm("gno.land/r/tests/vm"))

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        ChangeTreasury(cross(cur), target)
    })

    urequire.AbortsWithMessage(t, cur, "direct wallet call only", func() {
        ChangeRecovery(cross(cur), target)
    })

    urequire.Equal(t, testutils.TestAddress("wallet_treasury").String(), treasury.String())
    urequire.Equal(t, testutils.TestAddress("wallet_recovery").String(), recovery.String())
}

func TestMintAfterTreasuryChange(cur realm, t *testing.T) {
    oldAdmin, oldTreasury := admin, treasury
    oldOpened, oldPaused := opened, paused
    oldOpenedAt, oldPauseSeconds := openedAt, pauseSeconds
    oldTotal, oldPaid, oldFree := totalMinted, paidMinted, freeMinted
    oldReleased, oldCreatorMinted := releasedMinted, creatorMinted
    oldWhitelist, oldClaimed, oldPaidByWallet := whitelist, claimed, paidByWallet
    oldCollection, oldLedger := collection, ledger
    oldMeta, oldMetaLedger := nftMeta, metaLedger
    oldRoyalty, oldRoyaltyLedger := nftRoyalty, royaltyLedger

    defer func() {
        admin, treasury = oldAdmin, oldTreasury
        opened, paused = oldOpened, oldPaused
        openedAt, pauseSeconds = oldOpenedAt, oldPauseSeconds
        totalMinted, paidMinted, freeMinted = oldTotal, oldPaid, oldFree
        releasedMinted, creatorMinted = oldReleased, oldCreatorMinted
        whitelist, claimed, paidByWallet = oldWhitelist, oldClaimed, oldPaidByWallet
        collection, ledger = oldCollection, oldLedger
        nftMeta, metaLedger = oldMeta, oldMetaLedger
        nftRoyalty, royaltyLedger = oldRoyalty, oldRoyaltyLedger
    }()

    collection, ledger = grc721.NewToken("ERROR 404: PATUS NOT FOUND", "PATUS404", 0, cur)
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
    nftRoyalty, royaltyLedger = royalty.NewRoyalty(ledger, 500)

    admin = testutils.TestAddress("pay_chg_admin")
    previousTreasury := testutils.TestAddress("pay_chg_old")
    newTreasury := testutils.TestAddress("pay_chg_new")
    buyer := testutils.TestAddress("pay_chg_buyer")

    treasury = previousTreasury
    opened = true
    paused = false
    openedAt = time.Now().Unix()
    pauseSeconds = 0
    totalMinted, paidMinted, freeMinted = 0, 0, 0
    releasedMinted, creatorMinted = 0, 0

    whitelist = avl.Tree{}
    claimed = avl.Tree{}
    paidByWallet = avl.Tree{}

    testing.SetRealm(testing.NewUserRealm(admin))
    ChangeTreasury(cross(cur), newTreasury)

    readonly := banker.NewReadonlyBanker()
    previousBefore := readonly.GetCoins(previousTreasury).AmountOf("ugnot")
    newBefore := readonly.GetCoins(newTreasury).AmountOf("ugnot")

    testing.IssueCoins(chain.PackageAddress("gno.land/r/g1cfxu4vd25vc2xm6y8lx3v63cvm8gmxvswwmcux/patusworld404_onyx_v2"), chain.Coins{{Denom: "ugnot", Amount: 44000}})
    testing.SetRealm(testing.NewUserRealm(buyer))
    testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 44000}})

    Mint(cross(cur), 1, 44000)

    urequire.Equal(t, previousBefore, readonly.GetCoins(previousTreasury).AmountOf("ugnot"))
    urequire.Equal(t, newBefore+int64(44000), readonly.GetCoins(newTreasury).AmountOf("ugnot"))
    urequire.Equal(t, int64(0), readonly.GetCoins(chain.PackageAddress("gno.land/r/g1cfxu4vd25vc2xm6y8lx3v63cvm8gmxvswwmcux/patusworld404_onyx_v2")).AmountOf("ugnot"))
    urequire.Equal(t, int64(1), TotalSupply())
    urequire.Equal(t, buyer.String(), OwnerOf("1"))

    receiver, amount, err := RoyaltyInfo("1", 200000000)
    urequire.NoError(t, err)
    urequire.Equal(t, newTreasury.String(), receiver.String())
    urequire.Equal(t, int64(10000000), amount)
}

