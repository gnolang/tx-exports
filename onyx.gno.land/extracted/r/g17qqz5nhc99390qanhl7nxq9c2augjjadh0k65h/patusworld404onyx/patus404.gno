package patusworld404onyx

import (
    "chain/banker"
    "chain/runtime/unsafe"
    "strconv"
    "time"
    "gno.land/p/nt/avl/v0"
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
)

const (
    MaxSupply = 404
    PaidSupply = 378
    FreeSupply = 24
    BatchLimit = 10
    PaidWalletLimit = 10
    WhitelistSeconds int64 = 15 * 24 * 60 * 60
)

var (
    collection *grc721.Token
    ledger *grc721.PrivateLedger
    nftMeta *metadata.Metadata
    metaLedger *metadata.Ledger
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
    creatorMinted int
    whitelist avl.Tree
    claimed avl.Tree
    paidByWallet avl.Tree
)

func init(cur realm) {
    collection, ledger = grc721.NewToken("404 PATUS NOT FOUND", "PATUS404", 0, cur)
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
    admin = cur.Previous().Address()
    creator = admin
}

func requireAdmin(cur realm) {
    if cur.Previous().Address() != admin { panic("admin only") }
}

func Configure(cur realm, receiver, recoveryWallet, creatorWallet address) {
    requireAdmin(cur)
    if opened { panic("configuration frozen") }
    if !receiver.IsValid() || !recoveryWallet.IsValid() || !creatorWallet.IsValid() { panic("invalid address") }
    if receiver == admin { panic("treasury must differ from admin") }
    treasury, recovery, creator = receiver, recoveryWallet, creatorWallet
}

func SetWhitelist(cur realm, wallet address, enabled bool) {
    requireAdmin(cur)
    if opened { panic("whitelist frozen") }
    if !wallet.IsValid() { panic("invalid address") }
    old := whitelist.Get(wallet.String()) != nil
    if enabled && !old {
        if WhitelistCount() >= FreeSupply { panic("24 whitelist slots maximum") }
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
    who := cur.Previous().Address()
    if who != admin && who != recovery { panic("not authorized") }
    if !newAdmin.IsValid() { panic("invalid admin") }
    admin = newAdmin
}

func PriceAt(paidIndex int) int64 {
    if paidIndex < 0 || paidIndex >= PaidSupply { panic("paid supply exceeded") }
    if paidIndex < 24 { return 44000 }
    if paidIndex < 68 { return 96000 }
    if paidIndex < 334 { return 144000 }
    return 404000
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

func QuoteMint(wallet address, quantity int) int64 {
    if !opened || paused || quantity < 1 || quantity > BatchLimit { panic("mint unavailable or invalid quantity") }
    if totalMinted + quantity > MaxSupply - (2 - creatorMinted) { panic("creator reserve protected") }
    paidQty := quantity
    if FreeClaimAvailable(wallet) { paidQty-- }
    if paidMinted + paidQty > PaidSupply || PaidMintedBy(wallet) + paidQty > PaidWalletLimit { panic("paid limit exceeded") }
    var total int64
    for i := 0; i < paidQty; i++ { total += PriceAt(paidMinted+i) }
    return total
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
    for i := 0; i < quantity; i++ { mintOne(caller) }
    if free { claimed.Set(caller.String(), true); freeMinted++ }
    paidMinted += paidQty
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
