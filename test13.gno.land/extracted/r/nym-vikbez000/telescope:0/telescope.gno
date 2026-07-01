package telescope

import (
	"chain"
	"strconv"

	ns "gno.land/p/nym-vikbez000/nightsky0"
	registry "gno.land/r/nym-vikbez000/nightsky0"
)

var telescope *ns.TelescopeRealm

func init(cur realm) {
	owner := "g13kytw9mpyutwmyg5eq7arqxqcszfl6uq4p89zg"

	config := ns.NewTelescopeConfig(
		"vik telescope", // name
		"Seestar S30",   // model

		// Do not use too precise coordinates to keep some privacy
		49.02, // latitude
		1.15,  // longitude
		owner,
		cur.PkgPath(),
	)

	telescope = ns.NewTelescopeRealm(&config)
	telescope.Config.UpdateStatus("online")
	registry.Register(cross(cur), config)
}

func Render(path string) string {
	return telescope.RenderNightsky(path)
}

// Identity note: access control is keyed by the immediate caller via
// cur.Previous().Address() — the statically-scoped realm handle, not the
// stack-walking tx-origin. For a direct `gnokey maketx call` this resolves to
// the signing EOA (matching the address-keyed access list); a call routed
// through an intermediary realm is identified as that realm and denied unless
// explicitly granted. This is the phishing-resistant pattern recommended in
// gno-interrealm.md, and avoids the chain/runtime/unsafe primitives entirely.

// SubmitCommand allows authorized users to submit telescope commands.
// commandType: "capture" or "stop"
// targetRA: Right Ascension in hours (0-24), leave empty for stop
// targetDec: Declination in degrees (-90 to 90), leave empty for stop
// exposure: Exposure time in seconds (1-300), leave empty for stop
func SubmitCommand(cur realm, commandType, targetRA, targetDec, exposure string) {
	caller := cur.Previous().Address().String()

	var ra, dec float64
	var exp int
	if commandType == "capture" {
		// Reject malformed numbers instead of silently treating them as 0,
		// which would otherwise pass coordinate validation.
		var err error
		if ra, err = strconv.ParseFloat(targetRA, 64); err != nil {
			panic("invalid RA: must be a number")
		}
		if dec, err = strconv.ParseFloat(targetDec, 64); err != nil {
			panic("invalid Dec: must be a number")
		}
		if exp, err = strconv.Atoi(exposure); err != nil {
			panic("invalid exposure: must be an integer")
		}
	}

	telescope.SubmitCommand(caller, commandType, ra, dec, exp)
	chain.Emit("CommandSubmitted", "type", commandType, "requester", caller)
}

// GrantAccess allows the owner to grant access to another user.
// durationDays: 0 = never expires
func GrantAccess(cur realm, address string, durationDays int) {
	caller := cur.Previous().Address().String()
	telescope.GrantAccess(caller, address, durationDays)
	chain.Emit("AccessGranted", "address", address, "durationDays", strconv.Itoa(durationDays))
}

// RevokeAccess allows the owner to revoke access from a user.
func RevokeAccess(cur realm, address string) {
	caller := cur.Previous().Address().String()
	telescope.RevokeAccess(caller, address)
	chain.Emit("AccessRevoked", "address", address)
}

// GetNextCommand returns and removes the next command from the queue.
// Called by the telescope controller.
func GetNextCommand(cur realm) ns.TelescopeCommand {
	caller := cur.Previous().Address().String()
	return telescope.GetNextCommand(caller)
}

// UpdateStatus updates the telescope status locally and in the NightSky registry.
// Valid values: "online", "offline", "busy", "error"
func UpdateStatus(cur realm, status string) {
	switch status {
	case "online", "offline", "busy", "error":
	default:
		panic("invalid status: must be online, offline, busy, or error")
	}
	caller := cur.Previous().Address().String()
	telescope.UpdateStatus(caller, status)
	registry.UpdateTelescopeStatus(cross(cur), status)
}

// RecordCapture records a capture result locally and submits it to the NightSky network feed.
func RecordCapture(cur realm, imageURL string, targetRA, targetDec float64, exposure int, capturedBy string) {
	caller := cur.Previous().Address().String()
	telescope.RecordCapture(caller, imageURL, targetRA, targetDec, exposure, capturedBy)
	registry.SubmitCapture(cross(cur), imageURL, targetRA, targetDec, exposure, capturedBy)
	chain.Emit("CaptureRecorded", "imageURL", imageURL, "capturedBy", capturedBy)
}

// ClearCommandQueue clears all pending commands (emergency stop).
func ClearCommandQueue(cur realm) {
	caller := cur.Previous().Address().String()
	telescope.ClearCommandQueue(caller)
	chain.Emit("CommandQueueCleared", "by", caller)
}

func GetCommandCount() int      { return telescope.GetCommandCount() }
func GetCaptureCount() int      { return telescope.GetCaptureCount() }
func GetAccessRuleCount() int   { return telescope.GetAccessRuleCount() }
func GetStatus() string         { return telescope.Config.Status }
func GetTelescopeName() string  { return telescope.Config.Name }
func GetTelescopeModel() string { return telescope.Config.Model }
func GetOwner() string          { return telescope.OwnerAddress }
