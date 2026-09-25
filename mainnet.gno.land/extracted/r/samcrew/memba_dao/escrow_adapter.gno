package memba_dao
import("chain";"chain/banker";"chain/runtime";"gno.land/p/samcrew/memba_weighted_host";"gno.land/r/samcrew/escrow_v4")
func escrowState(a memba_weighted_host.EscrowAction)memba_weighted_host.EscrowState{
 p:=escrow_v4.PauseState();if p.Paused!=escrow_v4.IsPaused(){panic("invalid escrow pause read")}
 s:=memba_weighted_host.EscrowState{Owner:address(escrow_v4.GetAdmin()),PendingOwner:address(escrow_v4.GetPendingAdmin()),FeeRecipient:address(escrow_v4.GetFeeRecipient()),PendingFeeRecipient:address(escrow_v4.GetPendingFeeRecipient()),Paused:p.Paused,PausedAt:p.PausedAt,ExitsReopenAt:p.ExitsReopenAt,CooldownUntil:p.CooldownUntil,ExitsOpen:p.ExitsOpen}
 if a.IsResolution(){
  c:=escrow_v4.GetGovernanceContract(a.ContractID());s.Contract=memba_weighted_host.EscrowContract{Exists:c.Exists,ID:c.ID,ContentHash:c.ContentHash,Status:c.Status,Client:c.Client,Freelancer:c.Freelancer,Count:c.Count}
  for i,m:=range c.Milestones{s.Contract.Milestones[i]=memba_weighted_host.EscrowMilestone{ID:m.ID,Amount:m.Amount,Status:m.Status,FundedAt:m.FundedAt,CompletedAt:m.CompletedAt,DisputedAt:m.DisputedAt,PreDisputeStatus:m.PreDisputeStatus}}
 }
 if a.Kind()==memba_weighted_host.EscrowPayFreelancer{f:=escrow_v4.GetGovernanceFeeTerms();s.Fees=memba_weighted_host.EscrowFeeTerms{RawBPS:f.RawBPS,EffectiveBPS:f.EffectiveBPS,RawTreasury:f.RawTreasury,FallbackTreasury:f.FallbackTreasury,EffectiveTreasury:f.EffectiveTreasury}}
 return s
}
func proposeEscrow(cur realm,a memba_weighted_host.EscrowAction)uint64{return host.ProposeEscrow(a,escrowState(a),cur)}
func ProposeEscrowAccept(cur realm)uint64{return proposeEscrow(cur,escrowPolicy.Accept())}
func ProposeEscrowReturn(cur realm)uint64{return proposeEscrow(cur,escrowPolicy.Return())}
func ProposeEscrowAbortReturn(cur realm)uint64{return proposeEscrow(cur,escrowPolicy.AbortReturn())}
func ProposeEscrowUnpause(cur realm)uint64{return proposeEscrow(cur,memba_weighted_host.EscrowResume())}
func ProposeEscrowRefund(cur realm,id string,index int)uint64{return proposeEscrow(cur,memba_weighted_host.EscrowResolution(id,index,true))}
func ProposeEscrowPayFreelancer(cur realm,id string,index int)uint64{return proposeEscrow(cur,memba_weighted_host.EscrowResolution(id,index,false))}
// ProposeEscrowFeeRecipient stages recipient as the fallback fee recipient;
// recipient then accepts on escrow_v4 with its own AcceptFeeRecipient call.
func ProposeEscrowFeeRecipient(cur realm,recipient address)uint64{return proposeEscrow(cur,memba_weighted_host.EscrowFeeRecipient(recipient))}
func EmergencyPauseEscrow(cur realm){a:=memba_weighted_host.EscrowResume();before:=escrowState(a);host.PrepareEscrowEmergencyPause(before,cur);h:=runtime.ChainHeight();expected:=before;expected.Paused=true;expected.PausedAt=h;expected.ExitsReopenAt=h+escrow_v4.MaxPauseBlks;expected.ExitsOpen=false;escrow_v4.Pause(cross(cur));if escrowState(a)!=expected{panic("escrow pause postcondition mismatch")}}

type escrowBalance struct{who address;before,delta,want int64}
func escrowCredit(rows []escrowBalance,who address,amount int64)[]escrowBalance{
 if amount==0{return rows};if amount<0||!who.IsValid(){panic("invalid escrow credit")}
 if who==escrowPolicy.DAO()||who==chain.PackageAddress(memba_weighted_host.EscrowPath){panic("escrow payout cannot be trapped in governance or escrow")}
 for i:=range rows{if rows[i].who==who{rows[i].delta+=amount;return rows}}
 return append(rows,escrowBalance{who:who,delta:amount})
}
// Global solvency is checked at execution, not frozen at proposal creation:
// unrelated funding or dust may arrive while members vote. Aggregate aliases.
func escrowSettlement(a memba_weighted_host.EscrowAction,s memba_weighted_host.EscrowState)([]escrowBalance,int64){
 realmAddr:=chain.PackageAddress(memba_weighted_host.EscrowPath);amount:=s.Contract.Milestones[a.Milestone()].Amount
 liable:=escrow_v4.TotalLiabilities();bnk:=banker.NewReadonlyBanker()
 if amount<=0||liable<amount||bnk.GetCoin(realmAddr,"ugnot")<liable{panic("escrow is not solvent")}
 rows:=[]escrowBalance{{who:realmAddr,delta:-amount}}
 if a.Kind()==memba_weighted_host.EscrowRefundClient{rows=escrowCredit(rows,s.Contract.Client,amount)}else{
  bps:=s.Fees.EffectiveBPS;if bps<0||bps>500{panic("invalid escrow payout terms")}
  fee:=(amount/10000)*bps+((amount%10000)*bps)/10000
  rows=escrowCredit(rows,s.Contract.Freelancer,amount-fee);rows=escrowCredit(rows,s.Fees.EffectiveTreasury,fee)
 }
 for i:=range rows{
  r:=&rows[i];r.before=bnk.GetCoin(r.who,"ugnot")
  if r.before<0||(r.delta<0&&r.before< -r.delta)||(r.delta>0&&r.before>9223372036854775807-r.delta){panic("invalid escrow balance delta")}
  r.want=r.before+r.delta
 }
 return rows,liable-amount
}
func executeEscrow(cur realm,id uint64){
 proposed:=host.Proposal(id).EscrowAction;before:=escrowState(proposed);var balances []escrowBalance;var liabilityAfter int64
 if proposed.IsResolution(){balances,liabilityAfter=escrowSettlement(proposed,before)}
 a:=host.ConsumeEscrow(id,before,cur);expected:=before
 switch a.Kind(){
 case memba_weighted_host.EscrowAcceptOwner:expected.Owner=escrowPolicy.DAO();expected.PendingOwner="";escrow_v4.AcceptOwnership(cross(cur))
 case memba_weighted_host.EscrowReturnOwner:expected.PendingOwner=a.Recipient();escrow_v4.TransferOwnership(cross(cur),a.Recipient())
 case memba_weighted_host.EscrowAbortReturn:expected.PendingOwner="";escrow_v4.CancelOwnershipTransfer(cross(cur))
 case memba_weighted_host.EscrowUnpause:expected.Paused=false;expected.PausedAt=0;expected.ExitsReopenAt=0;expected.ExitsOpen=true;expected.CooldownUntil=runtime.ChainHeight()+escrow_v4.PauseCooldownBlks;escrow_v4.Unpause(cross(cur))
 case memba_weighted_host.EscrowSetFeeRecipient:expected.PendingFeeRecipient=a.Recipient();escrow_v4.ProposeFeeRecipient(cross(cur),a.Recipient())
 case memba_weighted_host.EscrowRefundClient,memba_weighted_host.EscrowPayFreelancer:
  refund:=a.Kind()==memba_weighted_host.EscrowRefundClient
  expected.Contract.Milestones[a.Milestone()].Status="released";if refund{expected.Contract.Milestones[a.Milestone()].Status="refunded"}
  // escrow_v4 settles the contract once every milestone is released or
  // refunded: completed if all were released, cancelled otherwise.
  expected.Contract.Status="active";allReleased,allTerminal:=true,true
  for i:=0;i<expected.Contract.Count;i++{m:=expected.Contract.Milestones[i];if m.Status=="disputed"{expected.Contract.Status="disputed"};if m.Status!="released"{allReleased=false};if m.Status!="released"&&m.Status!="refunded"{allTerminal=false}}
  if allTerminal{expected.Contract.Status="cancelled";if allReleased{expected.Contract.Status="completed"}}
  escrow_v4.ResolveDispute(cross(cur),a.ContractID(),a.Milestone(),refund)
 default:panic("unsupported escrow action")
 }
 if escrowState(a)!=expected{panic("escrow postcondition mismatch")}
 if a.IsResolution(){
  if escrow_v4.TotalLiabilities()!=liabilityAfter{panic("escrow liability postcondition mismatch")}
  bnk:=banker.NewReadonlyBanker();for _,r:=range balances{if bnk.GetCoin(r.who,"ugnot")!=r.want{panic("escrow balance postcondition mismatch")}}
  if bnk.GetCoin(chain.PackageAddress(memba_weighted_host.EscrowPath),"ugnot")<liabilityAfter{panic("escrow solvency postcondition mismatch")}
 }
}
