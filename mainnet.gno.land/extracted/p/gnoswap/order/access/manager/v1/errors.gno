package manager

import (
	"errors"
	"strings"
)

var (
	errAccessManagerLockedRole      = errors.New("access manager locked role")
	errAccessManagerBadConfirmation = errors.New("access manager bad confirmation")
	errAccessManagerLastAdmin       = errors.New("access manager last admin")
)

func errorWithDetails(err error, msgs ...string) error {
	if len(msgs) == 0 {
		return err
	}

	return errors.New(err.Error() + ", " + strings.Join(msgs, ", "))
}
