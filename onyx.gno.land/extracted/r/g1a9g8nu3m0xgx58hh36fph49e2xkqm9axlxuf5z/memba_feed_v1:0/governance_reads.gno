package memba_feed_v1

// GetModeratorCount exposes the exact grant count for DAO postconditions.
func GetModeratorCount() int { return moderators.Size() }
