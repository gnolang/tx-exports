// PKGPATH: gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate/filetests/z_events_filetest

// Every state change emits an event. Pulled, CreditDropped and the paid-time
// values (kept, carried) above 0 need a Pull, which only a session-signed
// transaction can reach; scripts/local-flow.sh checks them on a real chain.
package z_events_filetest

import (
	"testing"
	"time"

	"gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
)

const (
	payee = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5") // test1
	payer = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj") // test2
	gpub  = "gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c"
	sess  = address("g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh")
)

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(payee))
	id := mandate.Offer(cross(cur), "Weekly supporter", 1_000_000, 604800)
	testing.SetRealm(testing.NewUserRealm(payee))
	mandate.SetCollectorKey(cross(cur), gpub)
	testing.SetRealm(testing.NewUserRealm(payer))
	mandate.Subscribe(cross(cur), id, sess, time.Now().Unix()+86400)
	testing.SetRealm(testing.NewUserRealm(payer))
	mandate.Cancel(cross(cur), payer, sess)
	println(mandate.HasMandate(payer, id))
	// an expired mandate is dropped at its payer's next Subscribe
	testing.SetRealm(testing.NewUserRealm(payer))
	mandate.Subscribe(cross(cur), id, sess, time.Now().Unix()+60)
	testing.SkipHeights(13)
	testing.SetRealm(testing.NewUserRealm(payer))
	mandate.Subscribe(cross(cur), id, sess, time.Now().Unix()+86400)
}

// Output:
// false

// Events:
// [
//   {
//     "type": "PlanOffered",
//     "attrs": [
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payee",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "title",
//         "value": "Weekly supporter"
//       },
//       {
//         "key": "amount",
//         "value": "1000000"
//       },
//       {
//         "key": "period",
//         "value": "604800"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "CollectorKeySet",
//     "attrs": [
//       {
//         "key": "payee",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "pubkey",
//         "value": "gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c"
//       },
//       {
//         "key": "address",
//         "value": "g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "Subscribed",
//     "attrs": [
//       {
//         "key": "mandate",
//         "value": "1"
//       },
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payer",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "payee",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "session",
//         "value": "g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh"
//       },
//       {
//         "key": "expires",
//         "value": "1234654290"
//       },
//       {
//         "key": "first",
//         "value": "1234567890"
//       },
//       {
//         "key": "carried",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "Cancelled",
//     "attrs": [
//       {
//         "key": "mandate",
//         "value": "1"
//       },
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payer",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "by",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "kept",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "Subscribed",
//     "attrs": [
//       {
//         "key": "mandate",
//         "value": "2"
//       },
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payer",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "payee",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "session",
//         "value": "g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh"
//       },
//       {
//         "key": "expires",
//         "value": "1234567950"
//       },
//       {
//         "key": "first",
//         "value": "1234567890"
//       },
//       {
//         "key": "carried",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "MandatePruned",
//     "attrs": [
//       {
//         "key": "mandate",
//         "value": "2"
//       },
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payer",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "kept",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   },
//   {
//     "type": "Subscribed",
//     "attrs": [
//       {
//         "key": "mandate",
//         "value": "3"
//       },
//       {
//         "key": "plan",
//         "value": "1"
//       },
//       {
//         "key": "payer",
//         "value": "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj"
//       },
//       {
//         "key": "payee",
//         "value": "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
//       },
//       {
//         "key": "session",
//         "value": "g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh"
//       },
//       {
//         "key": "expires",
//         "value": "1234654355"
//       },
//       {
//         "key": "first",
//         "value": "1234567955"
//       },
//       {
//         "key": "carried",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
//   }
// ]
