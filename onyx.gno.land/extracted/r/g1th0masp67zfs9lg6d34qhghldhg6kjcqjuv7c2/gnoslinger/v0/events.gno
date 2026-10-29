package gnoslinger

import "chain"

// Events emitted by the realm (type, attribute keys):
//
//	GameCreated       id creator char seats maxTurns timeoutMinutes hex facing stake
//	PlayerJoined      id player seat char hex facing
//	PlanCommitted     id turn player seat
//	AllCommitted      id turn   (every character in the fight committed: the reveals start)
//	PlanRevealed      id turn seat by   (by: who sent the reveal, the player or the opener of its timelocked plan)
//	PlanUnopened      id turn seat reason   (a RevealMany skips a seat whose salt and plan do not match its commit or whose plan is not valid)
//	PlanPassed        id turn seat   (a player with no time points to play is passed automatically)
//	PlanMissed        id turn seat missed   (a claimed timeout passes the turn of a player whose plan is not in, no commit or never revealed; Out at the MaxMissed-th in a row)
//	PlayerSurrendered id turn player seat
//	TurnResolved      id turn rev seed
//	VictoryPoints id seat player reason points   (one per award at the end of a turn or of the showdown, rule 15; points < 0 for a loss)
//	GameEnded     id reason winner
//	PotPaid       id seat player amount   (ugnot; one per winner, a draw splitting the pot, stakes.gno)
//	StakeRefunded id seat player amount   (a showdown cancelled, or ended with everyone out of time, gives the stakes back)
//	HouseWithdrawn to amount
//	AdminChanged  admin
//	PlanDue       id turn turns to char vs left   (a turn started: one per player with a plan to send; char its character, vs the others', left the time the turn gives; notify.gno)
//	RevealDue     id turn turns to char vs   (the reveals started: one per player whose committed plan is not revealed)
//	ShowdownOver  id to char vs outcome   (the game ended: one per player, "you won", "you lost", "a draw"; a cancelled game, to the players who had joined)
//
// They land in transaction results; clients still poll Game.Rev to sync.
// PlanDue, RevealDue and ShowdownOver name their recipient, for the
// browser notifications (notify.gno).
func emit(typ string, attrs ...string) {
	chain.Emit(typ, attrs...)
}
