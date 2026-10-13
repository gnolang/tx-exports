package bolo

// Error is the type of every failure the registry reports (API C10, §7). Each one is
// a constant led by its copy key, the same keys v0 uses (UI spec §8).
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrNotUserCall Error = "err.use_wallet: not a direct transaction from a wallet"
	ErrSessionKey  Error = "err.master_key: a session key can't do this"
	ErrNotAdmin    Error = "err.not_allowed: only the admin can do this"
	ErrSetting     Error = "err.input: invalid setting"
)
