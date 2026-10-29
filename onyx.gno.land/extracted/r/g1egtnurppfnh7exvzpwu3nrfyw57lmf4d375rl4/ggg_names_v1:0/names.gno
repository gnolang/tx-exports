// Onyx v1.5.1-rc.1. No administrator, withdrawal, upgrade or arbitrary callback.
package ggg_names_v1

import (
 "chain"
 "chain/banker"
 "chain/runtime/unsafe"
 "strconv"
 "strings"
 "time"
)

const beneficiary = address("g1kw3pcg8std2w989me6akdj3lkv7m8fhefldc0t")
const renamePrice = int64(100000000)
type record struct { name string; revision int; history []change }
type change struct { oldName string; newName string; at int64 }
var profiles = make(map[address]record)
var active = make(map[string]address)
// Testnet policy: former names are permanently retired, preventing impersonation.
var retired = make(map[string]bool)

func Normalize(name string) string {
 if len(name)<3 || len(name)>16 { panic("NAME_LENGTH") }
 for _,c := range []byte(name) { if !((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_') { panic("NAME_CHARACTERS") } }
 n:=strings.ToLower(name)
 for _,r:=range []string{"admin","administrator","moderator","support","official","gnognogo","gnogno","gno_land","gnoland","gnot","adena","kiado","system"} { if n==r || strings.HasPrefix(n,r+"_") {panic("NAME_RESERVED")} }
 return n
}
func direct(cur realm) address {
 if !cur.IsCurrent() || !cur.Previous().IsUserCall() {panic("DIRECT_USER_CALL_REQUIRED")}
 return cur.Previous().Address()
}
// OriginSend alone is NOT proof. Both crossing entry points first verify the live
// realm and direct EOA caller; OriginSend banker additionally scopes spending to
// THIS message's envelope and recipient, never preexisting realm balances.
func envelope() chain.Coins { return unsafe.OriginSend() }
func available(name string) string {
 n:=Normalize(name)
 if active[n]!="" || retired[n] {panic("NAME_UNAVAILABLE")}
 return n
}
func Register(cur realm,name string) {
 owner:=direct(cur)
 if len(envelope())!=0 {panic("FIRST_REGISTRATION_NO_COMMERCIAL_PAYMENT")}
 if profiles[owner].name!="" {panic("ALREADY_REGISTERED")}
 n:=available(name)
 profiles[owner]=record{name:name,revision:1,history:[]change{{oldName:"",newName:name,at:time.Now().Unix()}}}
 active[n]=owner
}
func Rename(cur realm,expected string,revision int,name string) {
 owner:=direct(cur)
 previous:=profiles[owner]
 if previous.name=="" || previous.name!=expected || previous.revision!=revision {panic("OWNER_OR_REVISION_MISMATCH")}
 n:=available(name)
 coins:=envelope()
 if len(coins)!=1 || coins[0].Denom!="ugnot" || coins[0].Amount!=renamePrice {panic("EXACT_100_GNOT_REQUIRED")}
 b:=banker.NewBanker(banker.BankerTypeOriginSend,cur)
 // Send first: insufficient/consumed envelope aborts before indexes. A later
 // panic or storage-deposit failure rolls back the entire MsgCall, coins too.
 b.SendCoins(cur.Address(),beneficiary,chain.NewCoins(chain.Coin{Denom:"ugnot",Amount:renamePrice}))
 delete(active,strings.ToLower(previous.name))
 retired[strings.ToLower(previous.name)]=true
 previous.history=append(previous.history,change{oldName:previous.name,newName:name,at:time.Now().Unix()})
 previous.name=name;previous.revision++
 profiles[owner]=previous;active[n]=owner
}
func Lookup(addr string) string {
 p:=profiles[address(addr)]
 return "{\"name\":"+strconv.Quote(p.name)+",\"revision\":"+strconv.Itoa(p.revision)+"}"
}
func Owner(name string) string {return string(active[Normalize(name)])}
func Available(name string) bool {n:=Normalize(name);return active[n]==""&&!retired[n]}
func History(addr string) string {
 out:="["
 for i,c:=range profiles[address(addr)].history {if i>0 {out+=","};out+="{\"old\":"+strconv.Quote(c.oldName)+",\"name\":"+strconv.Quote(c.newName)+",\"at\":"+strconv.FormatInt(c.at,10)+"}"}
 return out+"]"
}
func RegistryVersion() string {return "GGG_NAMES_ONYX_V1:100000000ugnot:"+string(beneficiary)}
func Render(_ string) string {return "# GnoGno Go! · Onyx names\nPublic pseudonyms. First registration: network costs only. Rename: 100 GNOT plus network costs. Former names are retired. No gameplay, lives or Fast rights are granted here."}
