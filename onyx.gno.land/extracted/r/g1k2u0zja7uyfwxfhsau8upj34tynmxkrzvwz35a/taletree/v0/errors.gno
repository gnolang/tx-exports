package taletree

import "errors"

var (
	ErrPaused          = errors.New("taletree: writing is paused by the keeper")
	ErrUnauthorized    = errors.New("taletree: only the tale narrator or the keeper can do this")
	ErrNotKeeper       = errors.New("taletree: only the keeper can do this")
	ErrTaleNotFound    = errors.New("taletree: tale not found")
	ErrPassageNotFound = errors.New("taletree: passage not found")
	ErrPassageHidden   = errors.New("taletree: passage is hidden")
	ErrTaleLocked      = errors.New("taletree: tale is locked, no new passages")
	ErrIsEnding        = errors.New("taletree: this passage is an ending, it has no choices")
	ErrTooManyChoices  = errors.New("taletree: this passage already has the maximum number of choices")
	ErrTooDeep         = errors.New("taletree: the tale is too deep here, write an ending instead")
	ErrDuplicateChoice = errors.New("taletree: a sibling choice with the same text already exists")
	ErrTitleLength     = errors.New("taletree: title must be 3 to 80 bytes")
	ErrChoiceLength    = errors.New("taletree: choice must be 3 to 80 bytes")
	ErrBodyLength      = errors.New("taletree: passage must be 20 to 1500 bytes")
	ErrReasonLength    = errors.New("taletree: reason must be at most 140 bytes")
	ErrSelfCheer       = errors.New("taletree: you cannot cheer your own passage")
	ErrAlreadyCheered  = errors.New("taletree: you already cheered this passage")
	ErrSelfTip         = errors.New("taletree: you cannot tip your own passage")
	ErrTipCaller       = errors.New("taletree: tips must be sent directly by an account (gnokey maketx call)")
	ErrTipAmount       = errors.New("taletree: send a positive amount of ugnot, and only ugnot, with the tip")
	ErrNotHidden       = errors.New("taletree: passage is not hidden")
	ErrAlreadyHidden   = errors.New("taletree: passage is already hidden")
	ErrInvalidAddress  = errors.New("taletree: invalid address")
)
