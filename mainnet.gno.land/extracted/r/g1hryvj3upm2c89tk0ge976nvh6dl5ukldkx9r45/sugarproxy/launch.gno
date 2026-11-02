package sugarproxy

import (
	"chain"
	"strconv"
	"time"
)

// The launch: what the first install holds, and a launcher for its first two weeks (Jae, 2026-11-01: "Yes, 14-day
// window"). The launcher may add and remove sites, each counting at once, so the exact addresses video sites need
// can be found in minutes rather than a vote each; the guardian and GovDAO can remove anything it adds; it can't
// touch customers, hubs, payers or releases; and its power ends LaunchDays after the first install, for good.
//
// owner, launchSeed and launcher are written by deploy/realm/prepare.py just before the realm is deployed, from the
// hub's real pin and payer and the first release's hashes. The realm is deployed from a hot key (Jae's Ledger can't
// sign a transaction carrying the whole source) under that key's namespace, so the code itself names the owner,
// Jae's cold key: it is the first guardian and holds the first SUGAR; the deploying key ends up holding nothing.

const LaunchDays = 14

var (
	owner      address = "g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6"
	launcher   address = "g1w0p203thf56zndjsqv38hn8xm4jynzr7f2nkm9"
	launchSeed         = []string{
		"customer|sugar|sugar.video fetches the videos its users paste, to caption, translate and dub them",
		"hub|hub.sugar.video:8443|da9c7e1b22a7fb1c9af7aed7e4268691625718260ebeb57192d671c3758a04f8",
		"payer|g14qh9d2y2wrzwfhzneu8d4wx0fem93yq76zjsux",
		"release|0.1.0|darwin-amd64|255f74db2f00164f3236d7004a9628a1c1afa97bef44ee1a56e36c209e1056a5|https://sugar.video/proxy/dl/sugar-proxy-0.1.0-darwin-amd64",
		"release|0.1.0|darwin-arm64|d363ec51db2e869d561715bb7f5df8c0103fa035f8fd0f05f8e712df2d955332|https://sugar.video/proxy/dl/sugar-proxy-0.1.0-darwin-arm64",
		"release|0.1.0|linux-amd64|0db436c9ea1557d9560dc03e565b930f5539b79409a50e9cd80af99d68e57f39|https://sugar.video/proxy/dl/sugar-proxy-0.1.0-linux-amd64",
		"release|0.1.0|linux-arm64|98d784373569d758b9f0eee7acd3d6463e63ede1229770cbe3f9bcba886fde28|https://sugar.video/proxy/dl/sugar-proxy-0.1.0-linux-arm64",
		"release|0.1.0|windows-amd64|8e57e22bbc8951b2f86990a340f03567d330b48bb6807b636f3dce26207fb117|https://sugar.video/proxy/dl/sugar-proxy-0.1.0-windows-amd64.exe",
		"site|youtube.com|sugar|YouTube pages of the videos sugar.video users paste",
		"site|www.youtube.com|sugar|YouTube pages of the videos sugar.video users paste",
		"site|m.youtube.com|sugar|YouTube pages of the videos sugar.video users paste",
		"site|youtu.be|sugar|YouTube short links sugar.video users paste",
		"site|*.googlevideo.com|sugar|the video files of those YouTube videos",
		"site|vimeo.com|sugar|Vimeo pages of the videos sugar.video users paste",
		"site|player.vimeo.com|sugar|Vimeo's player for those videos",
		"site|*.vimeocdn.com|sugar|the video files of those Vimeo videos",
		"site|www.reddit.com|sugar|Reddit posts with the videos sugar.video users paste",
		"site|v.redd.it|sugar|the video files of those Reddit posts",
	}
	launchEnd  int64
)

// launch seeds the first install's items, counting at once (they are in the deployed code, which Jae signs), and
// starts the launcher's window. init calls it.
func launch() {
	launchEnd = time.Now().Unix() + LaunchDays*86400
	launching = true // the doc is written once, after the last item, not after each
	for _, p := range launchSeed {
		if _, err := add(p, "init"); err != nil {
			panic("launch item " + p + ": " + err.Error())
		}
	}
	launching = false
	publish()
}

// Launcher is the launcher's address and when its window ends (unix seconds).
func Launcher() (address, int64) { return launcher, launchEnd }

// LauncherAdd adds a site ("site|pattern|customer|purpose"), counting at once, from the launcher during its window.
func LauncherAdd(cur realm, payload string) int {
	mustLauncher(cur)
	kind, _, err := parse(payload)
	if err != nil {
		panic(err.Error())
	}
	if kind != KindSite {
		panic("the launcher adds sites only")
	}
	id, err := add(payload, "launcher")
	if err != nil {
		panic(err.Error())
	}
	return id
}

// LauncherRemove removes a site, from the launcher during its window.
func LauncherRemove(cur realm, id int) {
	mustLauncher(cur)
	if it := find(id); it == nil || it.Kind != KindSite {
		panic("the launcher removes sites only")
	}
	if err := end(id, false, "launcher"); err != nil {
		panic(err.Error())
	}
}

func mustLauncher(cur realm) {
	if launcher == "" || mustUser(cur) != launcher {
		panic("only the launcher may do that")
	}
	if time.Now().Unix() >= launchEnd {
		panic("the launch window ended at " + strconv.FormatInt(launchEnd, 10))
	}
	chain.Emit("Launcher", "by", launcher.String())
}
