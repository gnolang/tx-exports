package gnobuilders_badges_v2

// GetAdminCount is a value-only governance readback. It lets a proposal freeze
// the exact admin capacity before voting and verify the count after dispatch.
func GetAdminCount() int { return admins.Size() }
