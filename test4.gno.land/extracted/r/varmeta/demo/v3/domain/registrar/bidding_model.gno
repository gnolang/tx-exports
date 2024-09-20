package registrar

/*
	0: StatusFailed
	CurrentStatus:	1: NewBiddingSession
					2: AppendBiddingSession
					3: BiddingSessionClosed
	ActionCode:		1: CommitHashPhase
					2: CommitPricePhase
					3: ClaimPhase...
*/

type bidStatus struct {
	CurrentStatus currStatus
	ActionCode    actionCode
}

type (
	currStatus int
	actionCode int
)

var (
	StatusFailed         currStatus = 0
	NewBiddingSession    currStatus = 1
	AppendBiddingSession currStatus = 2
	BiddingSessionClosed currStatus = 3

	ActionFailed     actionCode = 0
	CommitHashPhase  actionCode = 1
	CommitPricePhase actionCode = 2
	ClaimPhase       actionCode = 3
)
