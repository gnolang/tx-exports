package nightsky

import (
	"chain"
	"time"

	"gno.land/p/moul/md"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	nightsky "gno.land/p/nym-vikbez000/nightsky0"
	"gno.land/r/sys/users"
)

// maxRecentCaptures is the number of captures kept in the network-wide feed.
const maxRecentCaptures = 50

var (
	// Registry of all telescopes in the network, keyed by realm pkgPath.
	// An avl.Tree is used over a map: the registry grows over time, only the
	// search path is loaded on access, and iteration is in deterministic
	// (sorted) key order — important for stable Render output.
	telescopes = avl.NewTree()

	// Recent captures from all telescopes (bounded, newest-first).
	recentCaptures = nightsky.NewCaptureFeed(maxRecentCaptures)
)

// Register registers a telescope realm in the NightSky network.
// Call from your realm's init() function:
//
//	nightsky.Register(cross(cur), config)
func Register(cur realm, cfg nightsky.TelescopeConfig) {
	submission := cur.Previous()
	pkgPath := submission.PkgPath()

	if submission.IsUser() {
		panic("Register must be called from realm code, not a user transaction")
	}

	if telescopes.Has(pkgPath) {
		return // already registered, silently ignore duplicate
	}

	if cfg.Name == "" || cfg.Model == "" || cfg.Owner == "" {
		panic("telescope name, model, and owner cannot be empty")
	}

	cfg.RealmPath = pkgPath

	telescopes.Set(pkgPath, cfg)

	chain.Emit("TelescopeRegistered", "pkgPath", pkgPath, "name", cfg.Name, "owner", cfg.Owner)
}

// UpdateTelescopeStatus allows a registered telescope realm to update its status in the registry.
// Call from your realm: nightsky.UpdateTelescopeStatus(cross(cur), "online")
func UpdateTelescopeStatus(cur realm, status string) {
	submission := cur.Previous()
	pkgPath := submission.PkgPath()

	if submission.IsUser() {
		panic("must be called from realm code")
	}

	config := mustGetTelescope(pkgPath)
	config.UpdateStatus(status)
	telescopes.Set(pkgPath, config)

	chain.Emit("StatusUpdate", "pkgPath", pkgPath, "status", status)
}

// SubmitCapture allows a registered telescope realm to add a capture to the network feed.
// Call from your realm: nightsky.SubmitCapture(cross(cur), imageURL, ra, dec, exposure, capturedBy)
func SubmitCapture(cur realm, imageURL string, targetRA, targetDec float64, exposure int, capturedBy string) {
	submission := cur.Previous()
	pkgPath := submission.PkgPath()

	if submission.IsUser() {
		panic("must be called from realm code")
	}

	config := mustGetTelescope(pkgPath)

	if imageURL == "" {
		panic("image URL cannot be empty")
	}

	recentCaptures.Add(nightsky.CaptureResult{
		ImageURL:    imageURL,
		TargetRA:    targetRA,
		TargetDec:   targetDec,
		Exposure:    exposure,
		CapturedBy:  capturedBy,
		CapturedAt:  time.Now(),
		TelescopeID: config.Name,
	})

	chain.Emit("NetworkCapture", "pkgPath", pkgPath, "telescope", config.Name, "imageURL", imageURL, "capturedBy", capturedBy)
}

// UnregisterTelescope removes a telescope realm from the network.
// Call from your realm: nightsky.UnregisterTelescope(cross(cur))
func UnregisterTelescope(cur realm) {
	submission := cur.Previous()
	pkgPath := submission.PkgPath()

	if submission.IsUser() {
		panic("must be called from realm code")
	}

	if _, removed := telescopes.Remove(pkgPath); !removed {
		panic("telescope not registered")
	}

	chain.Emit("TelescopeUnregistered", "pkgPath", pkgPath)
}

// mustGetTelescope returns the config for pkgPath or panics if not registered.
func mustGetTelescope(pkgPath string) nightsky.TelescopeConfig {
	value, exists := telescopes.Get(pkgPath)
	if !exists {
		panic("telescope not registered")
	}
	return value.(nightsky.TelescopeConfig)
}

// GetTelescopeCount returns the number of registered telescopes
func GetTelescopeCount() int {
	return telescopes.Size()
}

// GetOnlineTelescopeCount returns the number of online telescopes
func GetOnlineTelescopeCount() int {
	count := 0
	telescopes.Iterate("", "", func(_ string, value any) bool {
		if value.(nightsky.TelescopeConfig).Status == "online" {
			count++
		}
		return false
	})
	return count
}

func usernameOrAddressLink(addr string) string {
	user := users.ResolveAddress(address(addr))
	if user != nil {
		return user.RenderLink("")
	}
	return addr
}

func Render(path string) string {
	if path == "telescopes" {
		return renderTelescopeList()
	}

	if path == "captures" {
		return renderRecentCaptures()
	}

	if path == "map" {
		return renderTelescopeMap()
	}

	return renderMainPage()
}

func renderMainPage() string {
	out := ""
	out += md.H1("Gno NightSky 🔭")
	out += "Decentralized telescope network for stargazing\n\n"
	out += "Connect your smart telescope to the Gno.land blockchain and share access to the stars!\n\n"

	out += md.H2("Network Status")
	totalTelescopes := GetTelescopeCount()
	onlineTelescopes := GetOnlineTelescopeCount()
	out += ufmt.Sprintf("🔭 Total Telescopes: %d\n\n", totalTelescopes)
	out += ufmt.Sprintf("🟢 Online: %d\n\n", onlineTelescopes)
	out += ufmt.Sprintf("🔴 Offline: %d\n\n", totalTelescopes-onlineTelescopes)

	out += md.H2("Quick Links")
	out += md.Link("View All Telescopes", "/r/nym-vikbez000/nightsky0:telescopes") + "\n\n"
	out += md.Link("Recent Captures", "/r/nym-vikbez000/nightsky0:captures") + "\n\n"
	out += md.Link("Telescope Map", "/r/nym-vikbez000/nightsky0:map") + "\n\n"

	if latest, ok := recentCaptures.Latest(); ok {
		out += md.H2("Latest Capture")
		out += "![Latest capture](" + latest.ImageURL + ")\n\n"
		out += ufmt.Sprintf("_RA %.8fh · Dec %.8f° · %ds · %s_\n\n",
			latest.TargetRA, latest.TargetDec, latest.Exposure, latest.TelescopeID)
	}

	out += md.HorizontalRule()

	out += md.H2("How to Register Your Telescope")
	out += "Deploy your own telescope realm using the `/p/nym-vikbez000/nightsky0` package,\n"
	out += "then call `nightsky.Register(cross(cur), ...)` from your `init()` function.\n\n"
	out += "You can clone " + md.Link("my telescope realm", "/r/nym-vikbez000/telescope") + " as a starting point.\n\n"

	out += md.H2("About")
	out += "NightSky enables telescope owners to share access to their equipment through a decentralized network.\n\n"
	out += "Also take a look at " + md.Link("PiaGno", "https://github.com/gnoverse/piagno") + " 🎹\n\n"

	return out
}

func renderTelescopeList() string {
	out := ""
	out += md.H1("NightSky - Telescope Network")

	if telescopes.Size() == 0 {
		out += "\nNo telescopes registered yet.\n\n"
		out += md.Link("← Back to main page", "/r/nym-vikbez000/nightsky0") + "\n\n"
		return out
	}

	out += ufmt.Sprintf("\nTotal: %d telescopes\n\n", telescopes.Size())

	telescopes.Iterate("", "", func(_ string, value any) bool {
		config := value.(nightsky.TelescopeConfig)
		statusIcon := "🔴"
		switch config.Status {
		case "online":
			statusIcon = "🟢"
		case "busy":
			statusIcon = "🟡"
		case "error":
			statusIcon = "🔴"
		}

		out += md.H3(statusIcon + " " + config.Name)
		out += ufmt.Sprintf("**Model:** %s\n\n", config.Model)
		out += ufmt.Sprintf("**Owner:** %s\n\n", usernameOrAddressLink(config.Owner))
		out += ufmt.Sprintf("**Location:** %.4f°, %.4f°\n\n", config.Latitude, config.Longitude)
		out += ufmt.Sprintf("**Status:** %s\n\n", config.Status)
		out += ufmt.Sprintf("**Realm:** %s\n\n", md.Link("Visit", config.RealmPath))
		out += md.HorizontalRule()
		return false
	})

	out += md.Link("← Back to main page", "/r/nym-vikbez000/nightsky0") + "\n\n"

	return out
}

func renderRecentCaptures() string {
	out := ""
	out += md.H1("NightSky - Recent Captures")

	if recentCaptures.Len() == 0 {
		out += "\nNo captures yet.\n\n"
		out += md.Link("← Back to main page", "/r/nym-vikbez000/nightsky0") + "\n\n"
		return out
	}

	out += ufmt.Sprintf("\nShowing %d most recent captures\n\n", recentCaptures.Len())

	i := 0
	recentCaptures.IterateNewest(func(capture nightsky.CaptureResult) bool {
		i++
		out += md.H3(ufmt.Sprintf("Capture #%d", i))
		out += ufmt.Sprintf("**Telescope:** %s\n\n", capture.TelescopeID)
		out += ufmt.Sprintf("**Captured by:** %s\n\n", usernameOrAddressLink(capture.CapturedBy))
		out += ufmt.Sprintf("**Target:** RA %.8fh, Dec %.8f°\n\n", capture.TargetRA, capture.TargetDec)
		out += ufmt.Sprintf("**Exposure:** %d seconds\n\n", capture.Exposure)
		out += ufmt.Sprintf("**Image:** %s\n\n", md.Link("View", capture.ImageURL))
		out += md.HorizontalRule()
		return false
	})

	out += md.Link("← Back to main page", "/r/nym-vikbez000/nightsky0") + "\n\n"

	return out
}

func renderTelescopeMap() string {
	out := ""
	out += md.H1("NightSky - Telescope Map")
	out += "\n📍 Interactive map coming soon!\n\n"
	out += "For now, here are the telescope locations:\n\n"

	if telescopes.Size() == 0 {
		out += "No telescopes registered yet.\n\n"
	} else {
		telescopes.Iterate("", "", func(_ string, value any) bool {
			config := value.(nightsky.TelescopeConfig)
			out += ufmt.Sprintf("- **%s**: %.4f°, %.4f° (%s)\n\n",
				config.Name,
				config.Latitude,
				config.Longitude,
				config.Status,
			)
			return false
		})
	}

	out += md.Link("← Back to main page", "/r/nym-vikbez000/nightsky0") + "\n\n"

	return out
}
