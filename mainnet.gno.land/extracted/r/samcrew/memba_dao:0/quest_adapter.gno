// Closed, fixed-target quest authority adapter. Never recover dispatch failures.
package memba_dao

import (
    "gno.land/p/samcrew/memba_weighted_host"
    "gno.land/r/samcrew/memba_quest_attestation_v1"
)
func questState() memba_weighted_host.QuestState {
    return memba_weighted_host.QuestState{Owner:address(memba_quest_attestation_v1.GetOwner()),PendingOwner:address(memba_quest_attestation_v1.GetPendingOwner()),Signer:memba_quest_attestation_v1.GetSigner()}
}
func ProposeQuestAccept(cur realm) uint64 { return host.ProposeQuest(questPolicy.Accept(),questState(),cur) }
func ProposeQuestSigner(cur realm, key string) uint64 { return host.ProposeQuest(memba_weighted_host.QuestSigner(key),questState(),cur) }
func ProposeQuestReturn(cur realm) uint64 { return host.ProposeQuest(questPolicy.Return(),questState(),cur) }
func ProposeQuestAbortReturn(cur realm) uint64 { return host.ProposeQuest(questPolicy.AbortReturn(),questState(),cur) }
func executeQuest(cur realm,id uint64) {
    before:=questState();a:=host.ConsumeQuest(id,before,cur);expected:=before
    switch a.Kind() {
    case memba_weighted_host.QuestAcceptOwner:
        expected.Owner=questPolicy.DAO();expected.PendingOwner="";memba_quest_attestation_v1.AcceptOwnership(cross(cur))
    case memba_weighted_host.QuestSetSigner:
        expected.Signer=a.Key();memba_quest_attestation_v1.SetSigner(cross(cur),a.Key())
    case memba_weighted_host.QuestReturnOwner:
        expected.PendingOwner=a.Recipient();memba_quest_attestation_v1.TransferOwnership(cross(cur),a.Recipient())
    case memba_weighted_host.QuestAbortReturn:
        expected.PendingOwner="";memba_quest_attestation_v1.CancelOwnershipTransfer(cross(cur))
    default:panic("unsupported quest action")
    }
    if questState()!=expected { panic("quest postcondition mismatch") }
}
