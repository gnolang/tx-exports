// SPDX-License-Identifier: MIT
// Milestone Desk. Payment entitlements are decided by explicit, accepted rules;
// the chain does not decide whether off-chain work is good or truthful.
package milestonedesk

import (
 "chain"
 "chain/banker"
 "chain/runtime"
 "chain/runtime/unsafe"
 "crypto/bech32"
 "strconv"
 "strings"
)

type Milestone struct {
 Amount int64
 State string
 ProofURL string
 ProofHash string
 DeliveredAt int64
 ReviewEnd int64
 DisputeEnd int64
 Reason string
 ContractorPaid int64
 ClientRefund int64
 Outcome string
}
type Event struct { Height int64; Action string; Step int; Actor address; Detail string }
type Agreement struct {
 ID uint64
 Key string
 Fingerprint string
 Title string
 Client address
 Contractor address
 Arbiter address
 TermsHash string
 AcceptBy int64
 DeliverBy int64
 ReviewBlocks int64
 DisputeBlocks int64
 FallbackBPS int64
 State string
 Total int64
 Funded int64
 ClientOwed int64
 ContractorOwed int64
 ClientWithdrawn int64
 ContractorWithdrawn int64
 Steps []*Milestone
 Events []Event
}
var agreements = make(map[uint64]*Agreement)
var requestIDs = make(map[string]uint64)
var nextID uint64 = 1
var held int64
var vault address

func init(cur realm) { vault = cur.Address() }
func require(ok bool, message string) { if !ok { panic(message) } }
func number(n int64) string { return strconv.FormatInt(n,10) }
func idstr(n uint64) string { return strconv.FormatUint(n,10) }
func caller(cur realm, payable bool) address {
 require(cur.Previous().IsUserCall(), "direct wallet call required")
 if !payable { require(len(unsafe.OriginSend()) == 0, "this action accepts no coins") }
 return cur.Previous().Address()
}
func validAddress(s string) address {
 require(len(s)==40 && strings.HasPrefix(s,"g1"),"invalid Gno address")
 prefix, data, err := bech32.Decode(s)
 require(err==nil && prefix=="g" && len(data)==32,"invalid Gno address checksum")
 return address(s)
}
func hashOK(s string) bool {
 if len(s)!=64 { return false }
 for _, c := range s { if !((c>='0' && c<='9') || (c>='a' && c<='f')) { return false } }
 return s != strings.Repeat("0",64)
}
func textOK(s string, limit int) bool {
 if len(s)==0 || len(s)>limit { return false }
 for _,c := range s { if c<32 || c==127 { return false } }
 return true
}
func agreement(id uint64) *Agreement {
 a := agreements[id]; require(a!=nil,"agreement not found"); return a
}
func step(a *Agreement, index int) *Milestone {
 require(index>=0 && index<len(a.Steps),"milestone not found"); return a.Steps[index]
}
func record(a *Agreement, action string, index int, actor address, detail string) {
 a.Events=append(a.Events, Event{runtime.ChainHeight(),action,index,actor,detail})
 chain.Emit("MilestoneDesk", "agreement", idstr(a.ID), "action",action,"milestone",strconv.Itoa(index),"actor",actor.String())
}

// Create pins every economic term. An exact repeated key returns the existing
// agreement; reusing that key with changed terms is refused, even after expiry.
func Create(cur realm, key, title, contractor, arbiter, termsHash string, acceptBy, deliverBy, reviewBlocks, disputeBlocks, fallbackBPS int64, amounts string) uint64 {
 who:=caller(cur,false)
 require(textOK(key,96) && textOK(title,120),"invalid key or title")
 fingerprint:=strconv.Quote(title)+strconv.Quote(contractor)+strconv.Quote(arbiter)+strconv.Quote(termsHash)+":"+number(acceptBy)+":"+number(deliverBy)+":"+number(reviewBlocks)+":"+number(disputeBlocks)+":"+number(fallbackBPS)+":"+strconv.Quote(amounts)
 requestKey:=who.String()+"/"+key
 if old:=requestIDs[requestKey]; old!=0 {
  require(agreements[old].Fingerprint==fingerprint,"request key already has different terms")
  return old
 }
 worker:=validAddress(contractor); reviewer:=validAddress(arbiter)
 require(who!=worker && who!=reviewer && worker!=reviewer,"three distinct parties required")
 require(hashOK(termsHash),"terms hash must be a nonzero SHA-256 digest")
 height:=runtime.ChainHeight()
 require(acceptBy>height && acceptBy-height<=1000000,"acceptance deadline out of range")
 require(deliverBy>acceptBy && deliverBy-acceptBy<=1000000,"delivery deadline out of range")
 require(reviewBlocks>=2 && reviewBlocks<=1000000 && disputeBlocks>=2 && disputeBlocks<=1000000,"review and dispute windows must be 2 to 1000000 blocks")
 require(fallbackBPS>=0 && fallbackBPS<=10000,"fallback share must be 0 to 10000")
 parts:=strings.Split(amounts,","); require(len(parts)>0 && len(parts)<=12,"one to twelve milestones required")
 steps:=make([]*Milestone,0,len(parts)); var total int64
 for _,p:=range parts {
  v,err:=strconv.ParseInt(p,10,64);require(err==nil && v>0 && v<=1000000000,"invalid milestone amount")
  total+=v; require(total<=1000000000,"agreement exceeds 1000 GNOT")
  steps=append(steps,&Milestone{Amount:v,State:"unfunded"})
 }
 id:=nextID; nextID++
 a:=&Agreement{ID:id,Key:key,Fingerprint:fingerprint,Title:title,Client:who,Contractor:worker,Arbiter:reviewer,TermsHash:termsHash,AcceptBy:acceptBy,DeliverBy:deliverBy,ReviewBlocks:reviewBlocks,DisputeBlocks:disputeBlocks,FallbackBPS:fallbackBPS,State:"offered",Total:total,Steps:steps}
 agreements[id]=a; requestIDs[requestKey]=id; record(a,"created",-1,who,termsHash)
 return id
}
func Accept(cur realm,id uint64) {
 who:=caller(cur,false); a:=agreement(id)
 require(who==a.Contractor,"only the named contractor can accept")
 if a.State=="accepted" { return }
 require(a.State=="offered" && runtime.ChainHeight()<=a.AcceptBy,"offer not open for acceptance")
 a.State="accepted";record(a,"accepted",-1,who,a.TermsHash)
}
func CancelOffer(cur realm,id uint64) {
 who:=caller(cur,false);a:=agreement(id)
 require(who==a.Client,"only the client can cancel the offer")
 if a.State=="cancelled" { return }
 require(a.Funded==0 && (a.State=="offered" || a.State=="accepted"),"funded agreements cannot be cancelled")
 a.State="cancelled";record(a,"offer_cancelled",-1,who,"")
}
func Fund(cur realm,id uint64) {
 who:=caller(cur,true);a:=agreement(id)
 require(who==a.Client,"only the client can fund")
 require(a.State=="accepted" && runtime.ChainHeight()<=a.AcceptBy,"agreement not open for funding")
 coins:=unsafe.OriginSend()
 require(len(coins)==1 && coins[0].Denom=="ugnot" && coins[0].Amount==a.Total,"send the exact agreed ugnot amount")
 require(held<=9000000000000000-a.Total,"vault capacity reached")
 a.Funded=a.Total;held+=a.Total;a.State="active"
 for _,s:=range a.Steps {s.State="ready"}
 record(a,"funded",-1,who,number(a.Total))
}
func Deliver(cur realm,id uint64,index int,proofURL,proofHash string) {
 who:=caller(cur,false);a:=agreement(id);s:=step(a,index)
 require(who==a.Contractor,"only the contractor can deliver")
 if s.State=="review" && s.ProofHash==proofHash && s.ProofURL==proofURL {return}
 require(a.State=="active" && s.State=="ready","milestone not open for delivery")
 require(runtime.ChainHeight()<=a.DeliverBy,"delivery deadline passed")
 require(textOK(proofURL,512) && strings.HasPrefix(proofURL,"https://") && len(proofURL)>8,"HTTPS delivery URL required")
 require(hashOK(proofHash),"delivery hash must be a nonzero SHA-256 digest")
 s.ProofURL=proofURL;s.ProofHash=proofHash;s.DeliveredAt=runtime.ChainHeight()
 s.ReviewEnd=s.DeliveredAt+a.ReviewBlocks;s.State="review"
 record(a,"delivered",index,who,proofHash)
}
func settle(a *Agreement,s *Milestone,index int,workerShare int64,outcome string,who address) {
 require(s.State!="settled","milestone already settled")
 require(workerShare>=0 && workerShare<=s.Amount,"invalid settlement")
 s.ContractorPaid=workerShare;s.ClientRefund=s.Amount-workerShare;s.Outcome=outcome;s.State="settled"
 a.ContractorOwed+=workerShare;a.ClientOwed+=s.ClientRefund
 done:=true;for _,m:=range a.Steps {if m.State!="settled" {done=false}}
 if done {a.State="closed"}
 record(a,outcome,index,who,number(workerShare))
}
func Approve(cur realm,id uint64,index int) {
 who:=caller(cur,false);a:=agreement(id);s:=step(a,index)
 require(who==a.Client,"only the client can approve")
 if s.State=="settled" && s.Outcome=="approved" {return}
 require(s.State=="review","milestone is not awaiting review")
 settle(a,s,index,s.Amount,"approved",who)
}
func Dispute(cur realm,id uint64,index int,reason string) {
 who:=caller(cur,false);a:=agreement(id);s:=step(a,index)
 require(who==a.Client,"only the client can dispute delivery")
 if s.State=="disputed" && s.Reason==reason {return}
 require(s.State=="review" && runtime.ChainHeight()<=s.ReviewEnd,"review window closed")
 require(textOK(reason,500),"a bounded dispute reason is required")
 s.Reason=reason;s.DisputeEnd=runtime.ChainHeight()+a.DisputeBlocks;s.State="disputed"
 record(a,"disputed",index,who,reason)
}
func Resolve(cur realm,id uint64,index int,contractorBPS int64) {
 who:=caller(cur,false);a:=agreement(id);s:=step(a,index)
 require(who==a.Arbiter,"only the agreed arbiter can resolve")
 require(s.State=="disputed" && runtime.ChainHeight()<=s.DisputeEnd,"arbitration window closed")
 require(contractorBPS>=0 && contractorBPS<=10000,"invalid settlement share")
 settle(a,s,index,s.Amount*contractorBPS/10000,"arbitrated",who)
}
// Anyone can finalize an eligible milestone. No automated execution is implied:
// block height establishes eligibility; a transaction performs the transition.
func Finalize(cur realm,id uint64,index int) {
 who:=caller(cur,false);a:=agreement(id);s:=step(a,index);height:=runtime.ChainHeight()
 if s.State=="settled" {return}
 if s.State=="ready" {
  require(height>a.DeliverBy,"delivery window still open")
  settle(a,s,index,0,"missed_delivery",who)
 } else if s.State=="review" {
  require(height>s.ReviewEnd,"review window still open")
  settle(a,s,index,s.Amount,"review_expired",who)
 } else if s.State=="disputed" {
  require(height>s.DisputeEnd,"arbitration window still open")
  settle(a,s,index,s.Amount*a.FallbackBPS/10000,"fallback_split",who)
 } else {panic("milestone cannot be finalized")}
}
// Entitlements are recorded before transfers. Each party withdraws only their
// own balance; repeating a withdrawal returns zero instead of paying twice.
func Withdraw(cur realm,id uint64) int64 {
 who:=caller(cur,false);a:=agreement(id);var amount int64
 require(who==a.Client || who==a.Contractor,"only a payment party can withdraw")
 if who==a.Client {amount=a.ClientOwed} else {amount=a.ContractorOwed}
 if amount==0 {return 0}
 require(held>=amount,"vault accounting mismatch")
 if who==a.Client {a.ClientOwed=0;a.ClientWithdrawn+=amount} else {a.ContractorOwed=0;a.ContractorWithdrawn+=amount}
 held-=amount
 banker.NewBanker(banker.BankerTypeRealmSend,cur).SendCoins(cur.Address(),who,chain.Coins{{Denom:"ugnot",Amount:amount}})
 record(a,"withdrawn",-1,who,number(amount));return amount
}
