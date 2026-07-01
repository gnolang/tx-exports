// Package nightsky holds the shared types and single-telescope logic for the
// GnoNightSky telescope network.
//
// Note on panics: although this lives under p/, it is application-specific
// logic for the NightSky realms rather than a general-purpose reusable
// library. It deliberately panics on invalid input / failed preconditions
// (the assert-like style described in effective-gno) so the wrapping realms
// don't have to re-check every error. Callers that want softer handling
// should validate before calling.
package nightsky

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

// TelescopeConfig contains the settings and configuration for a telescope
type TelescopeConfig struct {
	Name       string    // Name of the telescope
	Model      string    // Telescope model (e.g., "Seestar S50")
	Latitude   float64   // Geographic location
	Longitude  float64   // Geographic location
	Owner      string    // Owner's gno address
	RealmPath  string    // Path to the telescope's realm (e.g., "/r/username/telescope")
	Status     string    // Current status: "online", "offline", "busy", "error"
	LastUpdate time.Time // Last status update
}

// AccessRule defines who can access a telescope
type AccessRule struct {
	AllowedAddress string    // Gno address allowed to access
	GrantedBy      string    // Who granted access
	GrantedAt      time.Time // When access was granted
	ExpiresAt      time.Time // When access expires (zero time = never)
}

// TelescopeCommand represents a command sent to a telescope
type TelescopeCommand struct {
	CommandType string    // "capture" or "stop"
	TargetRA    float64   // Right Ascension (for pointing/tracking)
	TargetDec   float64   // Declination (for pointing/tracking)
	Exposure    int       // Exposure time in seconds (for capture)
	RequestedBy string    // Who requested the command
	RequestedAt time.Time // When the command was requested
}

// CaptureResult represents the result of an image capture
type CaptureResult struct {
	ImageURL    string    // URL to the captured image (e.g., Imgur)
	TargetRA    float64   // Right Ascension of target
	TargetDec   float64   // Declination of target
	Exposure    int       // Exposure time in seconds
	CapturedBy  string    // Who captured the image
	CapturedAt  time.Time // When the image was captured
	TelescopeID string    // Which telescope captured it
}

// NewTelescopeConfig creates a new telescope configuration
func NewTelescopeConfig(name, model string, lat, lon float64, owner, realmPath string) TelescopeConfig {
	return TelescopeConfig{
		Name:       name,
		Model:      model,
		Latitude:   lat,
		Longitude:  lon,
		Owner:      owner,
		RealmPath:  realmPath,
		Status:     "offline",
		LastUpdate: time.Now(),
	}
}

// UpdateStatus updates the telescope status
func (t *TelescopeConfig) UpdateStatus(status string) {
	t.Status = status
	t.LastUpdate = time.Now()
}

// IsAccessAllowed checks if an address has a current (non-expired) access rule.
// rules is an avl.Tree keyed by allowed address holding AccessRule values.
func IsAccessAllowed(address string, rules *avl.Tree) bool {
	value, ok := rules.Get(address)
	if !ok {
		return false
	}
	rule := value.(AccessRule)
	return rule.ExpiresAt.IsZero() || time.Now().Before(rule.ExpiresAt)
}

// ValidateCommand validates a telescope command
func ValidateCommand(cmd TelescopeCommand, config TelescopeConfig) {
	switch cmd.CommandType {
	case "capture", "stop":
	default:
		panic("invalid command type: must be capture or stop")
	}

	if cmd.CommandType == "capture" {
		if cmd.TargetRA < 0 || cmd.TargetRA >= 24 {
			panic("invalid RA: must be between 0 and 24 hours")
		}
		if cmd.TargetDec < -90 || cmd.TargetDec > 90 {
			panic("invalid Dec: must be between -90 and 90 degrees")
		}
		if cmd.Exposure < 1 || cmd.Exposure > 300 {
			panic("invalid exposure time: must be between 1 and 300 seconds")
		}
	}
}

// maxCaptureHistory is the number of captures a single telescope keeps locally.
const maxCaptureHistory = 100

// TelescopeRealm manages a single telescope's state and operations
type TelescopeRealm struct {
	Config       *TelescopeConfig
	AccessRules  *avl.Tree // key: allowed address -> AccessRule
	CommandQueue []TelescopeCommand
	Captures     *CaptureFeed
	OwnerAddress string
}

// NewTelescopeRealm creates a new telescope realm instance
func NewTelescopeRealm(config *TelescopeConfig) *TelescopeRealm {
	return &TelescopeRealm{
		Config:       config,
		AccessRules:  avl.NewTree(),
		CommandQueue: []TelescopeCommand{},
		Captures:     NewCaptureFeed(maxCaptureHistory),
		OwnerAddress: config.Owner,
	}
}

// GrantAccess allows the owner to grant access to another user. Re-granting to
// an existing address overwrites the previous rule.
func (r *TelescopeRealm) GrantAccess(caller, address string, durationDays int) {
	r.checkOwner(caller)

	if address == "" {
		panic("address cannot be empty")
	}

	expiresAt := time.Time{} // Never expires by default
	if durationDays > 0 {
		expiresAt = time.Now().Add(time.Duration(durationDays) * 24 * time.Hour)
	}

	rule := AccessRule{
		AllowedAddress: address,
		GrantedBy:      r.OwnerAddress,
		GrantedAt:      time.Now(),
		ExpiresAt:      expiresAt,
	}

	r.AccessRules.Set(address, rule)
}

// RevokeAccess removes access for a specific address
func (r *TelescopeRealm) RevokeAccess(caller, address string) {
	r.checkOwner(caller)
	r.AccessRules.Remove(address)
}

// SubmitCommand allows authorized users to submit telescope commands
func (r *TelescopeRealm) SubmitCommand(caller, commandType string, targetRA, targetDec float64, exposure int) {
	// Check if caller has access (owner always has access)
	if caller != r.OwnerAddress {
		if !IsAccessAllowed(caller, r.AccessRules) {
			panic("access denied: you don't have permission to use this telescope")
		}
	}

	// Create command
	cmd := TelescopeCommand{
		CommandType: commandType,
		TargetRA:    targetRA,
		TargetDec:   targetDec,
		Exposure:    exposure,
		RequestedBy: caller,
		RequestedAt: time.Now(),
	}

	// Validate command
	ValidateCommand(cmd, *r.Config)

	// Add to queue
	r.CommandQueue = append(r.CommandQueue, cmd)

	// Update telescope status to busy
	r.Config.UpdateStatus("busy")
}

// GetNextCommand returns the next command in the queue (for telescope controller)
func (r *TelescopeRealm) GetNextCommand(caller string) TelescopeCommand {
	r.checkOwner(caller)

	if len(r.CommandQueue) == 0 {
		panic("no commands in queue")
	}

	cmd := r.CommandQueue[0]
	r.CommandQueue = r.CommandQueue[1:]

	return cmd
}

// UpdateStatus allows the owner to update telescope status
func (r *TelescopeRealm) UpdateStatus(caller string, status string) {
	r.checkOwner(caller)
	r.Config.UpdateStatus(status)
}

// RecordCapture allows the owner to record a capture result
func (r *TelescopeRealm) RecordCapture(caller, imageURL string, targetRA, targetDec float64, exposure int, capturedBy string) {
	r.checkOwner(caller)

	if imageURL == "" {
		panic("image URL cannot be empty")
	}

	capture := CaptureResult{
		ImageURL:    imageURL,
		TargetRA:    targetRA,
		TargetDec:   targetDec,
		Exposure:    exposure,
		CapturedBy:  capturedBy,
		CapturedAt:  time.Now(),
		TelescopeID: r.Config.Name,
	}

	r.Captures.Add(capture)

	// Update status back to online
	r.Config.UpdateStatus("online")
}

// ClearCommandQueue clears all pending commands (emergency stop)
func (r *TelescopeRealm) ClearCommandQueue(caller string) {
	r.checkOwner(caller)
	r.CommandQueue = []TelescopeCommand{}
	r.Config.UpdateStatus("online")
}

// GetCommandCount returns the number of pending commands
func (r *TelescopeRealm) GetCommandCount() int {
	return len(r.CommandQueue)
}

// GetCaptureCount returns the number of stored captures
func (r *TelescopeRealm) GetCaptureCount() int {
	return r.Captures.Len()
}

// GetAccessRuleCount returns the number of access rules
func (r *TelescopeRealm) GetAccessRuleCount() int {
	return r.AccessRules.Size()
}

// checkOwner verifies the caller is the owner
func (r *TelescopeRealm) checkOwner(caller string) {
	if caller != r.OwnerAddress {
		panic("access restricted: owner only")
	}
}
