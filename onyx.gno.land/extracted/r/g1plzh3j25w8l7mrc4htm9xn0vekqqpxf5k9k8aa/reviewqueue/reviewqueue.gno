package reviewqueue

import (
 "strconv"
 "strings"
)

type Workspace struct { ID int; Name string; Purpose string; Chair address }
type Review struct { Reviewer address; Verdict string; Reason string; Round int }
type Event struct { Sequence int; Actor address; Action string; Detail string; Round int }
type Proposal struct {
 ID int; WorkspaceID int; Author address; Title string; Summary string; Category string
 Status string; Round int; Reviewers []address; Reviews []Review; History []Event
}
var spaces []Workspace
var proposals []Proposal

func text(s string, max int) string {
 s = strings.TrimSpace(s)
 if len(s) == 0 || len(s) > max { panic("text is empty or exceeds limit") }
 for _, ch := range s { if ch < 32 && ch != '\n' && ch != '\t' { panic("control characters are not allowed") } }
 return s
}
func space(id int) *Workspace { if id < 1 || id > len(spaces) { panic("workspace not found") }; return &spaces[id-1] }
func proposal(id int) *Proposal { if id < 1 || id > len(proposals) { panic("proposal not found") }; return &proposals[id-1] }
func record(p *Proposal, actor address, action, detail string) {
 p.History = append(p.History, Event{len(p.History)+1,actor,action,detail,p.Round})
}
func CreateWorkspace(cur realm, name, purpose string) int {
 name = text(name,80); purpose = text(purpose,500)
 if len(spaces) >= 1000 { panic("workspace capacity reached") }
 id := len(spaces)+1
 spaces = append(spaces, Workspace{id,name,purpose,cur.Previous().Address()})
 return id
}
func Submit(cur realm, workspaceID int, title, summary, category string) int {
 space(workspaceID)
 title=text(title,120); summary=text(summary,3000); category=text(category,40)
 if len(proposals) >= 10000 { panic("proposal capacity reached") }
 id:=len(proposals)+1; actor:=cur.Previous().Address()
 p:=Proposal{ID:id,WorkspaceID:workspaceID,Author:actor,Title:title,Summary:summary,Category:category,Status:"submitted",Round:1}
 record(&p,actor,"submitted",title)
 proposals=append(proposals,p)
 return id
}
func AssignReviewers(cur realm, id int, first, second address) {
 p:=proposal(id); actor:=cur.Previous().Address()
 if actor != space(p.WorkspaceID).Chair { panic("only workspace chair may assign") }
 if p.Status != "submitted" { panic("proposal is not awaiting assignment") }
 if first == second || first == p.Author || second == p.Author { panic("two distinct non-author reviewers required") }
 // Address values must be valid bech32 addresses, not arbitrary strings.
 if !first.IsValid() || !second.IsValid() { panic("invalid reviewer address") }
 p.Reviewers=[]address{first,second}; p.Status="reviewing"
 record(p,actor,"reviewers assigned",string(first)+", "+string(second))
}
func SubmitReview(cur realm, id int, verdict, reason string) {
 p:=proposal(id); actor:=cur.Previous().Address()
 if p.Status != "reviewing" { panic("proposal is not in review") }
 if actor != p.Reviewers[0] && actor != p.Reviewers[1] { panic("only an assigned reviewer may review") }
 if verdict != "approve" && verdict != "changes" && verdict != "reject" { panic("invalid verdict") }
 reason=text(reason,1000)
 for _, r:=range p.Reviews { if r.Round==p.Round && r.Reviewer==actor { panic("one review per reviewer per round") } }
 p.Reviews=append(p.Reviews,Review{actor,verdict,reason,p.Round})
 record(p,actor,"review submitted",verdict+": "+reason)
}
func Finalize(cur realm, id int) {
 p:=proposal(id); actor:=cur.Previous().Address()
 if actor != space(p.WorkspaceID).Chair { panic("only workspace chair may finalize") }
 if p.Status != "reviewing" { panic("proposal is not in review") }
 count:=0; approves:=0; rejects:=0
 for _, r:=range p.Reviews { if r.Round==p.Round { count++; if r.Verdict=="approve" { approves++ }; if r.Verdict=="reject" { rejects++ } } }
 if count!=2 { panic("two reviews required before finalizing") }
 p.Status="changes"
 if approves==2 { p.Status="approved" }; if rejects==2 { p.Status="rejected" }
 record(p,actor,"decision finalized",p.Status)
}
func Revise(cur realm, id int, summary string) {
 p:=proposal(id); actor:=cur.Previous().Address()
 if actor!=p.Author { panic("only author may revise") }
 if p.Status!="changes" { panic("proposal is not awaiting changes") }
 summary=text(summary,3000)
 p.Summary=summary; p.Round++; p.Reviewers=nil; p.Status="submitted"
 record(p,actor,"revision submitted",summary)
}
func Withdraw(cur realm, id int) {
 p:=proposal(id); actor:=cur.Previous().Address()
 if actor!=p.Author { panic("only author may withdraw") }
 if p.Status!="submitted" && p.Status!="changes" { panic("cannot withdraw during or after review") }
 p.Status="withdrawn"; record(p,actor,"withdrawn","")
}
func Snapshot() string {
 out := "{\"workspaces\":["
 for i,s:=range spaces {
  if i>0 { out+="," }
  out+="{\"id\":"+strconv.Itoa(s.ID)+",\"name\":"+strconv.Quote(s.Name)+",\"chair\":"+strconv.Quote(string(s.Chair))+"}"
 }
 out+="],\"proposals\":["
 for i,p:=range proposals {
  if i>0 { out+="," }
  out+="{\"id\":"+strconv.Itoa(p.ID)+",\"title\":"+strconv.Quote(p.Title)+",\"summary\":"+strconv.Quote(p.Summary)+",\"status\":"+strconv.Quote(p.Status)+",\"round\":"+strconv.Itoa(p.Round)+"}"
 }
 return out+"]}"
}
func safe(s string) string {
 s=strings.ReplaceAll(s,"&","&amp;")
 s=strings.ReplaceAll(s,"<","&lt;"); s=strings.ReplaceAll(s,">","&gt;")
 for _, x:=range []string{"\\","*","_","[","]","#","`","|"} { s=strings.ReplaceAll(s,x,"\\"+x) }
 return s
}
func Render(path string) string {
 out:="# ReviewQueue\n\nShared proposals. Reasoned decisions. A public record.\n\n**Unaudited prototype. All content is public. No funds, token voting, identity verification, or proof of review quality.**\n\n"
 if strings.HasPrefix(path,"proposal/") {
  id,err:=strconv.Atoi(strings.TrimPrefix(path,"proposal/")); if err!=nil || id<1 || id>len(proposals) { return out+"Proposal not found." }
  p:=proposal(id); out+="## "+safe(p.Title)+"\n\n**"+p.Status+" · Round "+strconv.Itoa(p.Round)+"**\n\n"+safe(p.Summary)+"\n\n### Public history\n\n"
  for _,e:=range p.History { out+="- "+strconv.Itoa(e.Sequence)+" · "+safe(e.Action)+" · "+safe(string(e.Actor))+"\n\n  "+safe(e.Detail)+"\n" }
  return out
 }
 out+="## Workspaces\n\n"
 for _,s:=range spaces { out+="- **"+strconv.Itoa(s.ID)+" · "+safe(s.Name)+"** — "+safe(s.Purpose)+"\n" }
 out+="\n## Proposals\n\n"
 for i:=len(proposals)-1;i>=0;i-- { p:=proposals[i]; out+="- [#"+strconv.Itoa(p.ID)+" "+safe(p.Title)+"](:proposal/"+strconv.Itoa(p.ID)+") · "+p.Status+" · round "+strconv.Itoa(p.Round)+"\n" }
 return out+"\nUse the Actions tab to create a workspace, submit a proposal, assign two reviewers, review, and finalize. Two approvals approve; two rejections reject; all other combinations request changes. The chair cannot override the rule.\n"
}
