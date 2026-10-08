// Package catalog is GnoRadio's catalog rules, release 1: artists, tracks,
// albums, playlists, likes, follows, tips, support, moderation and
// verification. Other GnoRadio realms (radio, tickets, home) read it through
// the value getters in read.gno; it imports none of them.
//
// It keeps no state but its admin role. Every record lives in the data realm
// (gno.land/r/nym-alexiscolin000/gnoradio/data), in the "catalog/…" collections only the current
// catalog writer may change (db.gno). Promo budgets sit in data's vault, so a
// later release takes over the data and the coins without copying anything.
//
// Four track origins share one catalog:
//   - "artist":  published by the artist's own wallet, tips enabled;
//   - "curated": imported by the admin from CC0 / CC BY / CC BY-SA / CC BY-NC / CC BY-NC-SA sources;
//   - "audius", "jamendo": pointers the admin imports. The record keeps only
//     what the radio needs (platform id, genre, duration, licence); the app
//     reads title, artist and cover live, since both platforms' API terms
//     allow session caching only (attribution required).
//
// Imported artists start unclaimed; once the admin assigns them to
// a wallet (AssignArtist) or the robot verifies a claim, their tracks receive
// tips.
//
// Tips and support are forwarded in the same transaction: this realm ends
// every transaction holding no coins.
package catalog

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

const (
	version = "1.0.0"
	denom   = "ugnot"
	ugnot   = 1_000_000

	OriginArtist  = "artist"
	OriginCurated = "curated"
	OriginAudius  = "audius"
	OriginJamendo = "jamendo"

	minTip         = 100_000           // 0.1 GNOT
	maxTip         = 1_000_000 * ugnot // keeps share math far from overflow
	maxSplits      = 4
	maxSplitPct    = 90 // the artist always keeps at least 10%
	earlyBadges    = 10
	minDuration    = 10
	maxDuration    = 1200
	maxPerArtist   = 500 // tracks per artist
	maxAlbumTracks = 40
	maxListTracks  = 200
	maxUserLists   = 50
	maxFollows     = 1000
	maxUserReports = 5   // open reports per reporter
	maxTitle       = 64  // track, album and playlist titles, in characters
	maxBio         = 280 // artist bio
	maxCredits     = 160 // a track's credits and a curated import's attribution
	maxReason      = 200 // report and moderation reasons
	topSize        = 10
	maxSupportPct  = 50
)

// NumGenres is the size of the fixed genre list; genre ids are 1..NumGenres.
const NumGenres = 20

var genres = [NumGenres + 1]string{"",
	"Electronica", "Synthwave", "Ambient", "Techno", "House", "Drum & Bass", "Dubstep & Trap",
	"Lo-fi Beats", "Hip-hop & Rap", "R&B & Soul", "Rock & Indie", "Metal & Punk", "Pop",
	"Jazz & Blues", "Folk & Acoustic", "Cinematic & Classical", "World", "Latin", "Reggae & Dub", "Funk & Disco"}

// licenses an artist may pick; curated imports are limited to CC0, BY, BY-SA, BY-NC and BY-NC-SA
// (no ND, no reserved rights).
var licenses = []string{
	"CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "CC-BY-ND-4.0",
	"CC-BY-NC-4.0", "CC-BY-NC-SA-4.0", "CC-BY-NC-ND-4.0", "ALL-RIGHTS-RESERVED",
}

// AudiusLicense is the license id of tracks streamed from Audius.
const AudiusLicense = "Audius-OML"

const rightsTerms = "I own or control the rights to this recording and its composition, or hold a licence that allows this, and I grant the operator of GnoRadio and its users a worldwide, non-exclusive, royalty-free licence to store, stream, broadcast and display it through GnoRadio and gno.land for as long as it is published."

var (
	self  string     // this realm's path
	admin *role.Role // the moderator; nil when a release before renounced it
)

// init takes the admin over from the previous release (catalog/config
// "admin"), or names the deployer. While this realm is the catalog writer
// (release 1 at deploy) it also makes the catalog's collections.
func init(cur realm) {
	self = cur.PkgPath()
	holder, mirrored := data.Get(cConfig, "admin")
	if !mirrored {
		deployer := unsafe.OriginCaller()
		if deployer == "" && runtime.ChainID() == "dev" {
			deployer = chain.PackageAddress(self + "/dev") // gno test: a key nobody holds
		}
		holder = deployer.String()
	}
	if holder != "" {
		admin = role.New("admin", address(holder))
	}
	if data.Writer("catalog") == self {
		setup(cur, address(holder))
	}
}

// ---- helpers shared by every file ----

func now() int64 { return time.Now().Unix() }

func userCaller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("catalog: call this directly from your wallet")
	}
	return cur.Previous().Address()
}

// adminAddr is the admin: the data realm's mirror is the authority, so a
// change the previous release made after this one was deployed counts.
func adminAddr() address {
	h, ok := data.Get(cConfig, "admin")
	return role.Mirror(admin, h, ok)
}

// syncAdmin adopts the mirror when the previous release changed it after
// this one's init (during the release's delay).
func syncAdmin() {
	h, ok := data.Get(cConfig, "admin")
	admin = role.Adopt(admin, "admin", h, ok)
}

func onlyAdmin(cur realm) {
	syncAdmin()
	if admin == nil || !admin.Is(0, cur) {
		panic("catalog: admin only")
	}
	noPayment()
}

func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("catalog: this action does not take coins")
	}
}

// paid returns the ugnot attached to the call; anything else is refused.
func paid() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount <= 0 {
		panic("catalog: attach an amount in ugnot")
	}
	return sent[0].Amount
}

func emitEvent(name string, kv ...string) { chain.Emit(name, kv...) }

// ---- release and admin ----

// Ready tells the data realm that this release is on chain (see
// data.Propose). Anyone may call it.
func Ready(cur realm) {
	noPayment()
	data.Ready(cross(cur))
}

// OfferAdmin offers the admin role to an address (offering it to the admin
// cancels the offer); AcceptAdmin takes it. Each change is mirrored to the
// data realm, so the next release keeps the admin.
func OfferAdmin(cur realm, to address) {
	onlyAdmin(cur)
	admin.Offer(0, cur, to)
}

func AcceptAdmin(cur realm) {
	noPayment()
	syncAdmin()
	if admin == nil {
		panic("catalog: nothing offered to you")
	}
	admin.Accept(0, cur)
	data.Set(cross(cur), cConfig, "admin", admin.Holder().String())
}

// RenounceAdmin gives the admin role up for good, for this release and the
// next ones.
func RenounceAdmin(cur realm) {
	onlyAdmin(cur)
	admin.Renounce(0, cur)
	data.Set(cross(cur), cConfig, "admin", "")
}

// Render points gnoweb visitors to the GnoRadio site; a retired release says
// which realm took over.
func Render(_ string) string {
	home := strings.TrimPrefix(strings.TrimSuffix(self, "catalog/v1"), "gno.land") + "home/v1"
	d := strings.TrimPrefix(dataPath, "gno.land")
	out := "# GnoRadio · catalog\n\nThis contract holds GnoRadio's catalog rules; its data lives in [" + d + "](" + d +
		"). The site lives at [" + home + "](" + home + ").\n"
	if w := data.Writer("catalog"); w != self {
		out += "\nThis release is retired: the catalog is now `" + w + "`.\n"
	}
	return out
}

// Info is the catalog's summary for the app: counts, the admin and the
// realm that writes the catalog now ("current", this one unless retired).
func Info() string {
	t := rd()
	return `{"version":` + text.Str(version) + `,"artists":` + text.Itoa64(t.count(mArtists)) + `,"tracks":` + text.Itoa64(t.count(mTracks)) +
		`,"albums":` + text.Itoa64(t.count(mAlbums)) + `,"playlists":` + text.Itoa64(t.count(mPlaylists)) + `,"listeners":` + text.Itoa(data.Size(cUsers)) +
		`,"genres":` + text.Itoa(NumGenres) + `,"now":` + text.Itoa64(now()) + `,"current":` + text.Str(data.Writer("catalog")) +
		`,"admin":` + text.Str(adminAddr().String()) + `}`
}
