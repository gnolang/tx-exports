// Fixed arcade dispatch; no score-writing, fee or arbitrary-call authority.
package memba_dao
import (
    "gno.land/p/samcrew/memba_weighted_host"
    "gno.land/r/samcrew/memba_arcade_leaderboard_v1"
)
func arcadeState(a memba_weighted_host.ArcadeAction)memba_weighted_host.ArcadeState{
    owner:=memba_arcade_leaderboard_v1.GetOwner();subject:=false
    if a.Attester()!=""{subject=memba_arcade_leaderboard_v1.IsAttester(string(a.Attester()))}
    return memba_weighted_host.ArcadeState{Owner:owner,PendingOwner:memba_arcade_leaderboard_v1.GetPendingOwner(),Paused:memba_arcade_leaderboard_v1.IsPaused(),OwnerListed:memba_arcade_leaderboard_v1.IsAttester(string(owner)),DAOListed:memba_arcade_leaderboard_v1.IsAttester(string(arcadePolicy.DAO())),SuccessorListed:memba_arcade_leaderboard_v1.IsAttester(string(arcadePolicy.Successor())),SubjectListed:subject}
}
func ProposeArcadeAccept(cur realm)uint64{a:=arcadePolicy.Accept();return host.ProposeArcade(a,arcadeState(a),cur)}
func ProposeArcadeReturn(cur realm)uint64{a:=arcadePolicy.Return();return host.ProposeArcade(a,arcadeState(a),cur)}
func ProposeArcadeAbortReturn(cur realm)uint64{a:=arcadePolicy.AbortReturn();return host.ProposeArcade(a,arcadeState(a),cur)}
func ProposeArcadeAddAttester(cur realm,who address)uint64{a:=arcadePolicy.AddAttester(who);return host.ProposeArcade(a,arcadeState(a),cur)}
func ProposeArcadeRemoveAttester(cur realm,who address)uint64{a:=memba_weighted_host.ArcadeRevokeAttester(who);return host.ProposeArcade(a,arcadeState(a),cur)}
func ProposeArcadeUnpause(cur realm)uint64{a:=memba_weighted_host.ArcadeResume();return host.ProposeArcade(a,arcadeState(a),cur)}
func EmergencyPauseArcade(cur realm){
    a:=memba_weighted_host.ArcadeResume();before:=arcadeState(a);host.PrepareArcadeEmergencyPause(before,cur);expected:=before;expected.Paused=true
    memba_arcade_leaderboard_v1.Pause(cross(cur),true)
    if arcadeState(a)!=expected{panic("arcade pause postcondition mismatch")}
}
func executeArcade(cur realm,id uint64){
    proposed:=host.Proposal(id).ArcadeAction;before:=arcadeState(proposed);a:=host.ConsumeArcade(id,before,cur);expected:=before
    switch a.Kind(){
    case memba_weighted_host.ArcadeAcceptOwner:
        expected.Owner=arcadePolicy.DAO();expected.PendingOwner="";expected.OwnerListed=before.DAOListed;memba_arcade_leaderboard_v1.AcceptOwnership(cross(cur))
    case memba_weighted_host.ArcadeReturnOwner:
        expected.PendingOwner=a.Recipient();memba_arcade_leaderboard_v1.TransferOwnership(cross(cur),a.Recipient())
    case memba_weighted_host.ArcadeAbortReturn:
        expected.PendingOwner="";memba_arcade_leaderboard_v1.CancelOwnershipTransfer(cross(cur))
    case memba_weighted_host.ArcadeUnpause:
        expected.Paused=false;memba_arcade_leaderboard_v1.Pause(cross(cur),false)
    case memba_weighted_host.ArcadeAddAttester,memba_weighted_host.ArcadeRemoveAttester:
        listed:=a.Kind()==memba_weighted_host.ArcadeAddAttester;expected.SubjectListed=listed
        if a.Attester()==before.Owner{expected.OwnerListed=listed};if a.Attester()==arcadePolicy.DAO(){expected.DAOListed=listed};if a.Attester()==arcadePolicy.Successor(){expected.SuccessorListed=listed}
        if listed{memba_arcade_leaderboard_v1.AddAttester(cross(cur),a.Attester())}else{memba_arcade_leaderboard_v1.RemoveAttester(cross(cur),a.Attester())}
    default:panic("unsupported arcade action")
    }
    if arcadeState(a)!=expected{panic("arcade postcondition mismatch")}
    // Ownership operations preserve explicit appointments. IsAttester is the
    // allowlist bit; it is not the old owner's implicit authority.
    if a.Kind()==memba_weighted_host.ArcadeAcceptOwner && memba_arcade_leaderboard_v1.IsAttester(string(before.Owner))!=before.OwnerListed{panic("arcade old owner appointment changed")}
}
