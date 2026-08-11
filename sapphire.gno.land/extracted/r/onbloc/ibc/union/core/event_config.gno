package core

import "gno.land/r/onbloc/ibc/union/access"

const (
	defaultMaxEventAttrValueLen = 4096
	defaultMaxEventAttrPairs    = 50
)

var eventConfig = DefaultEventConfig()

// EventConfig controls host event attribute splitting and sizing.
type EventConfig struct {
	// SplitEventAttrs controls whether large event attributes are emitted as
	// indexed columns and whether split-dependent size checks are enforced.
	SplitEventAttrs bool

	// MaxEventAttrValueLen is the maximum value length of each split event
	// attribute column.
	MaxEventAttrValueLen uint

	// MaxEventAttrPairs is the shared key/value attr-pair budget for one host
	// event: packet_data's solo budget (MaxPacketDataEventSize) reserves one
	// pair here for its "<key>_size" attr, leaving MaxEventAttrPairs-1 for
	// value columns; IsValidEventSize checks the same budget for whichever
	// single variable-size field (ack, relayerMsg, marketMakerMsg) a
	// lifecycle event carries -- packet_data itself is no longer part of
	// those events. Mirrors chain.Emit's own MaxEventPairs ceiling (64), kept
	// comfortably under it to leave room for the event's other fixed attrs.
	MaxEventAttrPairs uint
}

// NewEventConfig constructs an EventConfig value. SetEventConfig validates the
// value before storing it.
func NewEventConfig(splitEventAttrs bool, maxEventAttrValueLen uint, maxEventAttrPairs uint) EventConfig {
	return EventConfig{
		SplitEventAttrs:      splitEventAttrs,
		MaxEventAttrValueLen: maxEventAttrValueLen,
		MaxEventAttrPairs:    maxEventAttrPairs,
	}
}

// DefaultEventConfig returns the default host event attribute policy.
func DefaultEventConfig() EventConfig {
	return EventConfig{
		SplitEventAttrs:      true,
		MaxEventAttrValueLen: defaultMaxEventAttrValueLen,
		MaxEventAttrPairs:    defaultMaxEventAttrPairs,
	}
}

// GetEventConfig returns the current host event attribute policy.
func GetEventConfig() EventConfig {
	return eventConfig
}

// SetEventConfig updates the host event attribute policy.
// The caller must be authorized for SelectorSetEventConfig.
func SetEventConfig(cur realm, config EventConfig) {
	access.AssertCanCall(0, cur, SelectorSetEventConfig)

	setEventConfig(config)
}

// SetSplitEventAttrs updates whether large event attributes are split.
// The caller must be authorized for SelectorSetEventConfig.
func SetSplitEventAttrs(cur realm, splitEventAttrs bool) {
	access.AssertCanCall(0, cur, SelectorSetEventConfig)

	config := GetEventConfig()
	config.SplitEventAttrs = splitEventAttrs
	setEventConfig(config)
}

// SetMaxEventAttrValueLen updates the maximum value length for each split
// event attribute column.
// The caller must be authorized for SelectorSetEventConfig.
func SetMaxEventAttrValueLen(cur realm, maxEventAttrValueLen uint) {
	access.AssertCanCall(0, cur, SelectorSetEventConfig)

	config := GetEventConfig()
	config.MaxEventAttrValueLen = maxEventAttrValueLen
	setEventConfig(config)
}

// SetMaxEventAttrPairs updates the shared event attr-pair budget.
// The caller must be authorized for SelectorSetEventConfig.
func SetMaxEventAttrPairs(cur realm, maxEventAttrPairs uint) {
	access.AssertCanCall(0, cur, SelectorSetEventConfig)

	config := GetEventConfig()
	config.MaxEventAttrPairs = maxEventAttrPairs
	setEventConfig(config)
}

func setEventConfig(config EventConfig) {
	assertValidEventConfig(config)
	eventConfig = config
}

func assertValidEventConfig(config EventConfig) {
	if config.MaxEventAttrValueLen == 0 {
		panic("max event attr value len must be positive")
	}
	if config.MaxEventAttrPairs == 0 {
		panic("max event attr pairs must be positive")
	}
}
