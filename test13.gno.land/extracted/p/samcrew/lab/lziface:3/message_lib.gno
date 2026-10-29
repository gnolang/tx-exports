package lziface

// MessageLibType represents the different types of message libraries
type MessageLibType uint8

type SetConfigParam struct {
	EID        uint32
	ConfigType uint32
	Config     []byte
}

const (
	Send MessageLibType = iota
	Receive
	SendAndReceive
)

// String representation for MessageLibType
func (m MessageLibType) String() string {
	return [...]string{"Send", "Receive", "SendAndReceive"}[m]
}

// MessageLib defines the interface for message libraries
type MessageLib interface {
	// IERC165 inheritance would be represented by including its interface methods
	// if we were fully implementing it in Go

	// SetConfig sets configuration parameters for an OApp
	SetConfig(oappPkgPath string, config []SetConfigParam)

	// GetConfig retrieves configuration for a specific endpoint and config type
	GetConfig(eid uint32, oappPkgPath string, configType uint32) []byte

	// IsSupportedEid checks if an endpoint ID is supported
	IsSupportedEid(eid uint32) bool

	// Version returns the version information
	Version() (major uint64, minor uint8, endpointVersion uint8)

	// MessageLibType returns the type of message library
	MessageLibType() MessageLibType
}
