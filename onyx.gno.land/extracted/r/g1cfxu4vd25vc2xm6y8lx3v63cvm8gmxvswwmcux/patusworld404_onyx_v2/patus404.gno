package patusworld404_onyx_v2

import (
    "chain/banker"
    "chain/runtime/unsafe"
    "strconv"
    "time"
    "gno.land/p/nt/avl/v0"
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
    "gno.land/p/nt/grc721/royalty/v0"
)

const (
    MaxSupply = 44
    PaidSupply = 36
    FreeSupply = 6
    BatchLimit = 10
    PaidWalletLimit = 10
    WhitelistSeconds int64 = 30 * 60
)

var (
    collection *grc721.Token
    ledger *grc721.PrivateLedger
    nftMeta *metadata.Metadata
    metaLedger *metadata.Ledger
    nftRoyalty *royalty.Royalty
    royaltyLedger *royalty.Ledger
    admin address
    recovery address
    creator address
    treasury address
    opened bool
    paused bool
    openedAt int64
    pausedAt int64
    pauseSeconds int64
    totalMinted int
    paidMinted int
    freeMinted int
    releasedMinted int
    creatorMinted int
    whitelist avl.Tree
    claimed avl.Tree
    paidByWallet avl.Tree
)

func init(cur realm) {
    collection, ledger = grc721.NewToken("ERROR 404: PATUS NOT FOUND", "PATUS404", 0, cur)
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
    nftRoyalty, royaltyLedger = royalty.NewRoyalty(ledger, 500)
    admin = cur.Previous().Address()
    creator = admin
}

func requireAdmin(cur realm) {
    if !cur.Previous().IsUserCall() { panic("direct wallet call only") }
    if cur.Previous().Address() != admin { panic("admin only") }
}

func Configure(cur realm, receiver, recoveryWallet, creatorWallet address) {
    requireAdmin(cur)
    if opened { panic("configuration frozen") }
    if !receiver.IsValid() || !recoveryWallet.IsValid() || !creatorWallet.IsValid() { panic("invalid address") }
    if receiver == admin { panic("treasury must differ from admin") }
    if err := royaltyLedger.SetDefaultRoyalty(receiver, 500); err != nil {
        panic(err)
    }
    treasury, recovery, creator = receiver, recoveryWallet, creatorWallet
}

// ChangeTreasury updates the mint and royalty receiver.
func ChangeTreasury(cur realm, newTreasury address) {
    requireAdmin(cur)
    if !newTreasury.IsValid() { panic("invalid address") }
    if newTreasury == admin { panic("treasury must differ from admin") }
    if err := royaltyLedger.SetDefaultRoyalty(newTreasury, 500); err != nil {
        panic(err)
    }
    treasury = newTreasury
}

// ChangeRecovery updates the recovery wallet.
func ChangeRecovery(cur realm, newRecovery address) {
    requireAdmin(cur)
    if !newRecovery.IsValid() { panic("invalid address") }
    recovery = newRecovery
}

func SetWhitelist(cur realm, wallet address, enabled bool) {
    requireAdmin(cur)
    if opened { panic("whitelist frozen") }
    if !wallet.IsValid() { panic("invalid address") }
    old := whitelist.Get(wallet.String()) != nil
    if enabled && !old {
        if WhitelistCount() >= FreeSupply { panic("6 whitelist slots maximum") }
        whitelist.Set(wallet.String(), true)
    } else if !enabled && old {
        whitelist.Remove(wallet.String())
    }
}

func WhitelistCount() int {
    return whitelist.Size()
}

func OpenMint(cur realm) {
    requireAdmin(cur)
    if opened { panic("already opened") }
    if !treasury.IsValid() || !recovery.IsValid() { panic("configure wallets first") }
    opened = true
    openedAt = time.Now().Unix()
}

func PauseMint(cur realm) {
    requireAdmin(cur)
    if !opened || paused { panic("mint not active") }
    paused = true
    pausedAt = time.Now().Unix()
}

func ResumeMint(cur realm) {
    requireAdmin(cur)
    if !paused { panic("not paused") }
    pauseSeconds += time.Now().Unix() - pausedAt
    pausedAt = 0
    paused = false
}

func ReplaceAdmin(cur realm, newAdmin address) {
    if !cur.Previous().IsUserCall() { panic("direct wallet call only") }
    who := cur.Previous().Address()
    if who != admin && who != recovery { panic("not authorized") }
    if !newAdmin.IsValid() { panic("invalid admin") }
    admin = newAdmin
}

func PriceAt(paidIndex int) int64 {
    if paidIndex < 0 || paidIndex >= PaidSupply { panic("paid supply exceeded") }
    if paidIndex < 4 { return 44 * 1000 }
    if paidIndex < 12 { return 96 * 1000 }
    if paidIndex < 28 { return 144 * 1000 }
    return 404 * 1000
}

func PaidMintedBy(wallet address) int {
    value := paidByWallet.Get(wallet.String())
    if value == nil { return 0 }
    return value.(int)
}

func IsWhitelisted(wallet address) bool { return whitelist.Get(wallet.String()) != nil }
func HasClaimed(wallet address) bool { return claimed.Get(wallet.String()) != nil }

func FreeClaimAvailable(wallet address) bool {
    if !opened || paused || freeMinted >= FreeSupply || !IsWhitelisted(wallet) || HasClaimed(wallet) { return false }
    elapsed := time.Now().Unix() - openedAt - pauseSeconds
    return elapsed < WhitelistSeconds || paidMinted < PaidSupply
}

// WhitelistReleased becomes true only after both expiration conditions.
func WhitelistReleased() bool {
    if !opened || paused || paidMinted < PaidSupply { return false }
    elapsed := time.Now().Unix() - openedAt - pauseSeconds
    return elapsed >= WhitelistSeconds
}

func ReleasedRemaining() int {
    if !WhitelistReleased() { return 0 }
    return FreeSupply - freeMinted - releasedMinted
}

func ReleasedMinted() int { return releasedMinted }

func QuoteMint(wallet address, quantity int) int64 {
    if !opened || paused || quantity < 1 || quantity > BatchLimit { panic("mint unavailable or invalid quantity") }
    if totalMinted + quantity > MaxSupply - (2 - creatorMinted) { panic("creator reserve protected") }

    paidQty := quantity
    if FreeClaimAvailable(wallet) { paidQty-- }

    originalQty := PaidSupply - paidMinted
    if originalQty > paidQty { originalQty = paidQty }

    releasedQty := paidQty - originalQty
    if releasedQty > 0 && (!WhitelistReleased() || releasedQty > ReleasedRemaining()) {
        panic("paid limit exceeded")
    }

    if PaidMintedBy(wallet) + paidQty > PaidWalletLimit { panic("paid limit exceeded") }

    var total int64
    for i := 0; i < originalQty; i++ {
        total += PriceAt(paidMinted+i)
    }
    total += int64(releasedQty) * 404 * 1000
    return total
}

// RoyaltyInfo returns the royalty receiver and amount for a secondary sale.
// The marketplace is responsible for honoring and paying the royalty.
func RoyaltyInfo(id string, salePrice int64) (address, int64, error) {
    return nftRoyalty.RoyaltyInfo(grc721.TokenID(id), salePrice)
}

func mintOne(to address) {
    totalMinted++
    tokenID := strconv.Itoa(totalMinted)
    uri, _ := catalogEntry(tokenID)
    if uri == "" { panic("missing catalog entry") }
    if err := ledger.Mint(to, grc721.TokenID(tokenID)); err != nil { panic(err) }
    if err := metaLedger.SetTokenURI(grc721.TokenID(tokenID), uri); err != nil { panic(err) }
}

// Mint accepts exactly the quoted amount in ugnot. maxAuthorized is a price ceiling,
// not an instruction to send more than the actual quote.
func Mint(cur realm, quantity int, maxAuthorized int64) {
    if !cur.Previous().IsUserCall() { panic("direct wallet call only") }
    caller := cur.Previous().Address()
    cost := QuoteMint(caller, quantity)
    if cost > maxAuthorized { panic("price changed: exceeds authorization") }
    sent := unsafe.OriginSend()
    if cost == 0 {
        if len(sent) != 0 { panic("free mint: no payment required") }
    } else if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != cost {
        panic("send exact quote in ugnot")
    }
    free := FreeClaimAvailable(caller)
    paidQty := quantity
    if free { paidQty-- }

    originalQty := PaidSupply - paidMinted
    if originalQty > paidQty { originalQty = paidQty }
    releasedQty := paidQty - originalQty

    for i := 0; i < quantity; i++ { mintOne(caller) }
    if free { claimed.Set(caller.String(), true); freeMinted++ }

    paidMinted += originalQty
    releasedMinted += releasedQty
    paidByWallet.Set(caller.String(), PaidMintedBy(caller)+paidQty)
    if cost > 0 {
        bank := banker.NewBanker(banker.BankerTypeRealmSend, cur)
        bank.SendCoins(cur.Address(), treasury, sent)
    }
}

func MintCreator(cur realm) {
    if cur.Previous().Address() != creator { panic("creator only") }
    if creatorMinted >= 2 { panic("creator reserve exhausted") }
    if opened && paused { panic("paused") }
    if totalMinted >= MaxSupply { panic("supply exhausted") }
    if len(unsafe.OriginSend()) != 0 { panic("creator mint is free") }
    mintOne(creator)
    creatorMinted++
}

// Name returns the collection name.
func Name() string { return collection.GetName() }

// Symbol returns the collection symbol.
func Symbol() string { return collection.GetSymbol() }

// BalanceOf returns the number of NFTs owned by a wallet.
func BalanceOf(owner address) (int64, error) {
    return collection.BalanceOf(owner)
}

func TotalSupply() int64 { return collection.TotalSupply() }
func PaidMinted() int { return paidMinted }
func FreeMinted() int { return freeMinted }
func CreatorMinted() int { return creatorMinted }
func RemainingSupply() int { return MaxSupply-totalMinted }
func OwnerOf(id string) string {
    owner, err := collection.OwnerOf(grc721.TokenID(id))
    if err != nil { return "" }
    return owner.String()
}
func TokenURI(id string) string {
    uri, err := nftMeta.TokenURI(grc721.TokenID(id))
    if err != nil { return "" }
    return uri
}
func TokenMetadata(id grc721.TokenID) (string, error) {
    _, err := collection.OwnerOf(id)
    if err != nil { return "", err }
    _, json := catalogEntry(string(id))
    return json, nil
}
func TransferFrom(cur realm, from, to address, id string) {
    if err := ledger.TransferFrom(cur.Previous().Address(), from, to, grc721.TokenID(id)); err != nil { panic(err) }
}

// Approve authorizes an address to transfer a specific NFT.
func Approve(cur realm, to address, id string) {
    if err := ledger.CallerTeller().Approve(0, cur, to, grc721.TokenID(id)); err != nil {
        panic(err)
    }
}

// SetApprovalForAll authorizes or revokes an operator for all NFTs owned by the caller.
func SetApprovalForAll(cur realm, operator address, approved bool) {
    if err := ledger.CallerTeller().SetApprovalForAll(0, cur, operator, approved); err != nil {
        panic(err)
    }
}

// GetApproved returns the approved address for a specific NFT.
func GetApproved(id string) (address, error) {
    return collection.GetApproved(grc721.TokenID(id))
}

// IsApprovedForAll checks whether an operator is authorized by an owner.
func IsApprovedForAll(owner, operator address) bool {
    return collection.IsApprovedForAll(owner, operator)
}
