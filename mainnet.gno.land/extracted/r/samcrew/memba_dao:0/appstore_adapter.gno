package memba_dao
import("strings";"gno.land/p/samcrew/memba_weighted_host";"gno.land/r/samcrew/memba_appstore_v3")
func appstoreState(a memba_weighted_host.AppstoreAction)memba_weighted_host.AppstoreState{
 owner:=memba_appstore_v3.GetOwner();s:=memba_weighted_host.AppstoreState{Owner:owner,PendingOwner:memba_appstore_v3.GetPendingOwner(),Treasury:memba_appstore_v3.GetTreasury(),Fee:memba_appstore_v3.GetRegistrationFee(),Paused:memba_appstore_v3.IsPaused(),Sealed:memba_appstore_v3.IsSeedingSealed(),OwnerCurator:memba_appstore_v3.IsCurator(string(owner)),DAOCurator:memba_appstore_v3.IsCurator(string(appstorePolicy.DAO())),SuccessorCurator:memba_appstore_v3.IsCurator(string(appstorePolicy.Successor()))}
 if a.Kind()==memba_weighted_host.AppstoreAddCurator||a.Kind()==memba_weighted_host.AppstoreRemoveCurator{s.SubjectCurator=memba_appstore_v3.IsCurator(string(a.Recipient()))}
 if a.IsListing(){l:=memba_appstore_v3.GetGovernanceListing(a.Path(),a.Kind()==memba_weighted_host.AppstoreClearFlags);s.Listing=memba_weighted_host.AppstoreListing{Exists:l.Exists,ContentHash:l.ContentHash,Status:l.Status,Reason:l.Reason,Credit:l.Credit,Flags:l.Flags,ClearKeys:l.ClearKeys}}
 return s
}
func proposeAppstore(cur realm,a memba_weighted_host.AppstoreAction)uint64{return host.ProposeAppstore(a,appstoreState(a),cur)}
func ProposeAppstoreAccept(cur realm)uint64{return proposeAppstore(cur,appstorePolicy.Accept())}
func ProposeAppstoreReturn(cur realm)uint64{return proposeAppstore(cur,appstorePolicy.Return())}
func ProposeAppstoreAbortReturn(cur realm)uint64{return proposeAppstore(cur,appstorePolicy.AbortReturn())}
func ProposeAppstoreTreasury(cur realm)uint64{return proposeAppstore(cur,appstorePolicy.SetTreasury())}
func ProposeAppstoreFee(cur realm,fee int64)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreRegistrationFee(fee))}
func ProposeAppstoreCurator(cur realm,who address,grant bool)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreCurator(who,grant))}
func ProposeAppstoreUnpause(cur realm)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreResume())}
func ProposeAppstoreSeal(cur realm)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreSealImport())}
func ProposeAppstoreApprove(cur realm,path string)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreModeration(memba_weighted_host.AppstoreApprove,path,""))}
func ProposeAppstoreReject(cur realm,path,reason string)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreModeration(memba_weighted_host.AppstoreReject,path,reason))}
func ProposeAppstoreDelist(cur realm,path string)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreModeration(memba_weighted_host.AppstoreDelist,path,""))}
func ProposeAppstoreRestore(cur realm,path string)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreModeration(memba_weighted_host.AppstoreRestore,path,""))}
func ProposeAppstoreClearFlags(cur realm,path string)uint64{return proposeAppstore(cur,memba_weighted_host.AppstoreModeration(memba_weighted_host.AppstoreClearFlags,path,""))}
func EmergencyPauseAppstore(cur realm){a:=memba_weighted_host.AppstoreResume();before:=appstoreState(a);host.PrepareAppstoreEmergencyPause(before,cur);expected:=before;expected.Paused=true;memba_appstore_v3.Pause(cross(cur),true);if appstoreState(a)!=expected{panic("appstore pause postcondition mismatch")}}
func executeAppstore(cur realm,id uint64){
 proposed:=host.Proposal(id).AppstoreAction;before:=appstoreState(proposed);a:=host.ConsumeAppstore(id,before,cur);expected:=before
 switch a.Kind(){
 case memba_weighted_host.AppstoreAccept:
  expected.Owner=appstorePolicy.DAO();expected.PendingOwner="";expected.OwnerCurator=true;expected.DAOCurator=true;if before.Owner==appstorePolicy.Successor(){expected.SuccessorCurator=false};memba_appstore_v3.AcceptOwnership(cross(cur))
 case memba_weighted_host.AppstoreReturn:expected.PendingOwner=a.Recipient();memba_appstore_v3.TransferOwnership(cross(cur),a.Recipient())
 case memba_weighted_host.AppstoreAbortReturn:expected.PendingOwner="";memba_appstore_v3.CancelOwnershipTransfer(cross(cur))
 case memba_weighted_host.AppstoreFee:expected.Fee=a.Fee();memba_appstore_v3.SetRegistrationFee(cross(cur),a.Fee())
 case memba_weighted_host.AppstoreTreasury:expected.Treasury=a.Recipient();memba_appstore_v3.SetTreasury(cross(cur),a.Recipient())
 case memba_weighted_host.AppstoreUnpause:expected.Paused=false;memba_appstore_v3.Pause(cross(cur),false)
 case memba_weighted_host.AppstoreSeal:expected.Sealed=true;memba_appstore_v3.FinalizeSeed(cross(cur))
 case memba_weighted_host.AppstoreAddCurator,memba_weighted_host.AppstoreRemoveCurator:
  grant:=a.Kind()==memba_weighted_host.AppstoreAddCurator;expected.SubjectCurator=grant;if a.Recipient()==before.Owner{expected.OwnerCurator=grant};if a.Recipient()==appstorePolicy.DAO(){expected.DAOCurator=grant};if a.Recipient()==appstorePolicy.Successor(){expected.SuccessorCurator=grant};if grant{memba_appstore_v3.AddCurator(cross(cur),a.Recipient())}else{memba_appstore_v3.RemoveCurator(cross(cur),a.Recipient())}
 case memba_weighted_host.AppstoreApprove:expected.Listing.Status="live";memba_appstore_v3.ApproveApp(cross(cur),a.Path())
 case memba_weighted_host.AppstoreReject:expected.Listing.Status="rejected";expected.Listing.Reason=a.Reason();expected.Listing.Credit=true;memba_appstore_v3.RejectApp(cross(cur),a.Path(),a.Reason())
 case memba_weighted_host.AppstoreDelist:expected.Listing.Status="delisted";memba_appstore_v3.DelistApp(cross(cur),a.Path())
 case memba_weighted_host.AppstoreRestore:expected.Listing.Status="pending";memba_appstore_v3.RestoreApp(cross(cur),a.Path())
 case memba_weighted_host.AppstoreClearFlags:
  keys:=strings.Split(before.Listing.ClearKeys,",");if len(keys)>memba_appstore_v3.MaxClearBatch||len(keys)>before.Listing.Flags{panic("invalid appstore clear batch")};expected.Listing.Flags-=len(keys);expected.Listing.ClearKeys=""
  memba_appstore_v3.ClearFlags(cross(cur),a.Path())
  for _,who:=range keys{if memba_appstore_v3.HasGovernanceFlag(a.Path(),who){panic("appstore clear dedupe postcondition mismatch")}}
 default:panic("unsupported appstore action")
 }
 after:=appstoreState(a);if a.Kind()==memba_weighted_host.AppstoreClearFlags{after.Listing.ClearKeys=""}
 if after!=expected{panic("appstore postcondition mismatch")}
 if a.Kind()==memba_weighted_host.AppstoreAccept&&memba_appstore_v3.IsCurator(string(before.Owner)){panic("appstore previous curator retained")}
}
