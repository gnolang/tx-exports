// SPDX-License-Identifier: MIT
package milestonedesk

import("chain/banker";"chain/runtime";"strconv";"strings")

func q(s string) string { return strconv.Quote(s) }
func AgreementJSON(id uint64) string {
 a:=agreement(id)
 out:=`{"id":`+idstr(id)+`,"title":`+q(a.Title)+`,"key":`+q(a.Key)+`,"client":`+q(a.Client.String())+`,"contractor":`+q(a.Contractor.String())+`,"arbiter":`+q(a.Arbiter.String())+`,"termsHash":`+q(a.TermsHash)+`,"acceptBy":`+number(a.AcceptBy)+`,"deliverBy":`+number(a.DeliverBy)+`,"reviewBlocks":`+number(a.ReviewBlocks)+`,"disputeBlocks":`+number(a.DisputeBlocks)+`,"fallbackBPS":`+number(a.FallbackBPS)+`,"state":`+q(a.State)+`,"total":`+number(a.Total)+`,"funded":`+number(a.Funded)+`,"clientOwed":`+number(a.ClientOwed)+`,"contractorOwed":`+number(a.ContractorOwed)+`,"clientWithdrawn":`+number(a.ClientWithdrawn)+`,"contractorWithdrawn":`+number(a.ContractorWithdrawn)+`,"steps":[`
 for i,s:=range a.Steps {
  if i>0 {out+=","}
  out+=`{"amount":`+number(s.Amount)+`,"state":`+q(s.State)+`,"proofURL":`+q(s.ProofURL)+`,"proofHash":`+q(s.ProofHash)+`,"deliveredAt":`+number(s.DeliveredAt)+`,"reviewEnd":`+number(s.ReviewEnd)+`,"disputeEnd":`+number(s.DisputeEnd)+`,"reason":`+q(s.Reason)+`,"contractorPaid":`+number(s.ContractorPaid)+`,"clientRefund":`+number(s.ClientRefund)+`,"outcome":`+q(s.Outcome)+`}`
 }
 out+=`],"events":[`
 for i,e:=range a.Events {
  if i>0 {out+=","}
  out+=`{"height":`+number(e.Height)+`,"action":`+q(e.Action)+`,"step":`+strconv.Itoa(e.Step)+`,"actor":`+q(e.Actor.String())+`,"detail":`+q(e.Detail)+`}`
 }
 return out+`]}`
}
func ListJSON(before uint64,limit int) string {
 require(limit>=1 && limit<=25,"page size must be 1 to 25")
 if before==0 || before>nextID {before=nextID}
 out:=`{"height":`+number(runtime.ChainHeight())+`,"total":`+idstr(nextID-1)+`,"items":[`
 count:=0;id:=before
 for id>1 && count<limit {
  id--;if count>0 {out+=","};out+=AgreementJSON(id);count++
 }
 return out+`],"nextBefore":`+idstr(id)+`}`
}
func Lookup(client,key string) uint64 { return requestIDs[client+"/"+key] }
func LookupJSON(client,key string) string {
 return `{"id":`+idstr(Lookup(client,key))+`}`
}
func VaultJSON() string {
 balance:=banker.NewReadonlyBanker().GetCoin(vault,"ugnot")
 return `{"address":`+q(vault.String())+`,"held":`+number(held)+`,"balance":`+number(balance)+`,"solvent":`+strconv.FormatBool(balance>=held)+`,"agreements":`+idstr(nextID-1)+`,"height":`+number(runtime.ChainHeight())+`}`
}
func safeTitle(s string) string {
 for _,c:=range []string{"[","]","<",">","*","_","`","#","|","\\"} {s=strings.ReplaceAll(s,c,"")}
 return s
}
func Render(path string) string {
 out:="# Milestone Desk\n\nWork agreed. Payment accounted for.\n\nEvery agreement pins both parties, a delivery deadline, a review window and the fallback split if the agreed arbiter is unavailable. Claims require transactions; work quality is assessed by the parties.\n\n"
 if path=="" {
  out+="## Agreements\n\n"
  start:=nextID-1;var n int
  for start>0 && n<25 {a:=agreements[start];out+="- ["+safeTitle(a.Title)+"](:"+idstr(start)+") · "+a.State+" · "+number(a.Total)+" ugnot\n";start--;n++}
  return out+"\n## Accounting\n\n"+"```json\n"+VaultJSON()+"\n```\n"
 }
 id,err:=strconv.ParseUint(path,10,64);if err!=nil || agreements[id]==nil {return out+"Agreement not found."}
 a:=agreements[id];out+="## "+safeTitle(a.Title)+"\n\nState: **"+a.State+"**. Delivery deadline: block **"+number(a.DeliverBy)+"**.\n\n"
 for i,s:=range a.Steps {out+="- Milestone "+strconv.Itoa(i+1)+": "+number(s.Amount)+" ugnot · **"+s.State+"** · "+s.Outcome+"\n"}
 return out+"\n```json\n"+AgreementJSON(id)+"\n```\n"
}
