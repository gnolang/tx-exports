// PKGPATH: gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate/filetests/z_pages_filetest

// Golden copies of every page, built through the exported API only.
package z_pages_filetest

import (
	"testing"
	"time"

	"gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate"
)

const (
	payee  = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5") // test1
	payer  = address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj") // test2
	payer2 = address("g1rzuwh5frve732k4futyw45y78rzuty4626zy6h") // test3
	gpub   = "gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c"
	sess   = address("g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh")
	sess2  = address("g1valkxsym77y3qlj5fq9h4p64y73l3masvuxav0")
)

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(payee))
	id := mandate.Offer(cross(cur), "Weekly *coffee* for g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 $5", 1_000_000, 604800)
	testing.SetRealm(testing.NewUserRealm(payee))
	mandate.Offer(cross(cur), "Demo | one minute", 250_000, 60)
	testing.SetRealm(testing.NewUserRealm(payee))
	mandate.SetCollectorKey(cross(cur), gpub)
	testing.SetRealm(testing.NewUserRealm(payer))
	mandate.Subscribe(cross(cur), id, sess, time.Now().Unix()+30*86400)
	testing.SetRealm(testing.NewUserRealm(payer2))
	mandate.Subscribe(cross(cur), id, sess2, time.Now().Unix()+30*86400)
	testing.SetRealm(testing.NewUserRealm(payer2))
	mandate.Cancel(cross(cur), payer2, sess2)

	for _, p := range []string{"", "plan/1", "plan/2", "payer/" + payer.String(), "payer/" + payer2.String(), "payee/" + payee.String(), "help", "nope"} {
		println("==== Render(\"" + p + "\")")
		println(mandate.Render(p))
	}
}

// Output:
// ==== Render("")
// # Mandate
//
// **Subscriptions and direct debit on native GNOT.** A creator publishes a plan, such as 1 GNOT every week. A supporter signs one permission from their own wallet: *at most this much, every period, through this realm only, until I cancel or it expires*. The creator's collector then pulls each payment at the start of the period, and this realm checks who, how much and when before it forwards the coins.
//
// ## The honest limits
//
// - **It is direct debit, not escrow.** Nothing is locked up front. A supporter can stop at any time, and a creator is only paid when a pull succeeds.
// - **A hard cap the supporter sets.** The chain never lets a pull take more than the session's spend limit per period: the plan's amount plus a fee allowance of 0.1 GNOT. A dishonest creator could at worst burn that allowance as network fees; they can never take more, or pull more often.
// - **At most 16 mandates per wallet**, because the chain allows 16 session keys per account.
// - **Revoke any time.** Revoking the session on chain stops every pull at once. The realm cannot see a revoke, so a mandate still shows here as active until it is cancelled or expires: [how to stop a mandate](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:help).
// - **One realm, nothing under it.** A session for this realm also covers any realm deployed under its path, so nothing will ever be deployed there.
// - No admin, no pause, no upgrade. The realm never holds funds: each payment goes straight to the creator in the same transaction.
//
// [How to use it, with every command](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:help)
//
// ## Numbers
//
// | Plans | Mandates ever recorded | Payments | Paid out |
// |---|---|---|---|
// | 2 | 2 | 0 | 0 GNOT |
//
// ## Supporter pages
//
// No plan has been paid for in its current or last period.
//
// Only plans that someone has paid for are listed here. [All plans, newest first](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:plans)
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("plan/1")
// # Plan #1: Weekly \*coffee\* for&#32;g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 \$5
//
// **1 GNOT every week** to [g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payee/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5)
//
// Plan 1 · published 2009-02-13 23:31 UTC · 0 payments in the current period (since 2009-02-12 00:00 UTC), 0 in the one before · 0 payments, 0 GNOT in total · last payment: never
//
// Plans never change. New terms are published as a new plan.
//
// ## Supporters
//
// No paying supporters.
//
// Supporters are listed and counted from their first payment on, newest first, while their mandate is active. Cancelled and expired mandates are not listed or counted; a supporter who revoked the session on chain stays listed until the mandate is cancelled or expires. 1 active mandate has not paid yet (not listed).
//
// ## Support this plan
//
// You need [gnokey](https://docs.gno.land) and a key with some GNOT on onyx-1. Replace `YOUR_KEY` with your key's name. You can support one plan of each creator at a time: every plan of a creator is collected by the same key, and the chain allows one session per key. To switch plans, cancel and revoke first (time you paid for carries over to the same plan only). These two commands give the creator's collector key (`g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh`) the right to take **at most 1.1 GNOT every week** (the price plus a fee allowance), through this realm only, for one year.
//
// 1. Create the session (your own key; it cannot be done with a session). If the chain answers `session key address collides with existing account`, this collector key can no longer be used for new sessions: ask the creator to publish a new one.
//
// ```
// gnokey maketx session create -pubkey gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c -allow-paths vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -spend-limit 1100000ugnot -spend-period 604800 -expires-at 1266103890 -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// 2. Record the terms here:
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Subscribe -args 1 -args g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh -args 1266103890 -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// The first payment is collected right after, then one every week. If you paid for this plan before and that period has not ended (you cancelled, the creator cancelled, or your mandate expired), the new mandate's first payment waits until it ends, so time you paid for is not charged twice. The one exception: a wallet keeps paid time for at most 16 plans it has left; beyond that, a creator's cancel keeps nothing for that creator's plan, and your own cancel or expiry lets the period that ends soonest go. Your page at `/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payer/<your address>` shows how to stop.
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("plan/2")
// # Plan #2: Demo | one minute
//
// **0.25 GNOT every minute** to [g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payee/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) (a test plan: the period is under a day)
//
// Plan 2 · published 2009-02-13 23:31 UTC · 0 payments in the current period (since 2009-02-13 23:31 UTC), 0 in the one before · 0 payments, 0 GNOT in total · last payment: never
//
// Plans never change. New terms are published as a new plan.
//
// ## Supporters
//
// No paying supporters.
//
// Supporters are listed and counted from their first payment on, newest first, while their mandate is active. Cancelled and expired mandates are not listed or counted; a supporter who revoked the session on chain stays listed until the mandate is cancelled or expires. 0 active mandates have not paid yet (not listed).
//
// ## Support this plan
//
// You need [gnokey](https://docs.gno.land) and a key with some GNOT on onyx-1. Replace `YOUR_KEY` with your key's name. You can support one plan of each creator at a time: every plan of a creator is collected by the same key, and the chain allows one session per key. To switch plans, cancel and revoke first (time you paid for carries over to the same plan only). These two commands give the creator's collector key (`g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh`) the right to take **at most 0.35 GNOT every minute** (the price plus a fee allowance), through this realm only, for one year.
//
// 1. Create the session (your own key; it cannot be done with a session). If the chain answers `session key address collides with existing account`, this collector key can no longer be used for new sessions: ask the creator to publish a new one.
//
// ```
// gnokey maketx session create -pubkey gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c -allow-paths vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -spend-limit 350000ugnot -spend-period 60 -expires-at 1266103890 -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// 2. Record the terms here:
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Subscribe -args 2 -args g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh -args 1266103890 -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// The first payment is collected right after, then one every minute. If you paid for this plan before and that period has not ended (you cancelled, the creator cancelled, or your mandate expired), the new mandate's first payment waits until it ends, so time you paid for is not charged twice. The one exception: a wallet keeps paid time for at most 16 plans it has left; beyond that, a creator's cancel keeps nothing for that creator's plan, and your own cancel or expiry lets the period that ends soonest go. Your page at `/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payer/<your address>` shows how to stop.
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("payer/g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")
// # Mandates of g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj
//
// Each mandate lets one creator's collector key pull a fixed amount once per period. To stop one completely, run both commands shown under it: **revoke** removes the session on chain (no pull can be signed any more) and **cancel** ends the mandate here. Revoke alone already stops every payment.
//
// ## Mandate 1: [plan #1 Weekly \*coffee\* for&#32;g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 \$5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:plan/1)
//
// - Status here: **active** (if you revoked the session on chain, no payment can be taken)
// - Price: 1 GNOT every week to [g1jg8mtu…sqf5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payee/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5)
// - Session key: `g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh`
// - Payments: 0, 0 GNOT in total, last: never
// - Next payment allowed from: 2009-02-13 23:31 UTC · ends: 2009-03-15 23:31 UTC
//
// Revoke the session (your own key):
//
// ```
// gnokey maketx session revoke -pubkey gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// Cancel the mandate (your own key):
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Cancel -args g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj -args g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("payer/g1rzuwh5frve732k4futyw45y78rzuty4626zy6h")
// # Mandates of g1rzuwh5frve732k4futyw45y78rzuty4626zy6h
//
// Each mandate lets one creator's collector key pull a fixed amount once per period. To stop one completely, run both commands shown under it: **revoke** removes the session on chain (no pull can be signed any more) and **cancel** ends the mandate here. Revoke alone already stops every payment.
//
// ## Mandate 2: [plan #1 Weekly \*coffee\* for&#32;g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 \$5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:plan/1)
//
// - Status here: **cancelled**
// - Price: 1 GNOT every week to [g1jg8mtu…sqf5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payee/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5)
// - Session key: `g1valkxsym77y3qlj5fq9h4p64y73l3masvuxav0`
// - Payments: 0, 0 GNOT in total, last: never
//
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("payee/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
// # Creator g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5
//
// | Plans | Payments | Received | Last payment |
// |---|---|---|---|
// | 2 | 0 | 0 GNOT | never |
//
// Collector key: `g1psdsf789f4xw3qrpjue54g2h28syd09yfkrxdh` (`gpub1pgfj7ard9eg82cjtv4u4xetrwqer2dntxyfzxz3pqfp0696ldln2nm7kd33zfpgypg6u0e7upl03hyeexa6mccn4ce8mkswg65c`)
//
// ## Plans
//
// | Plan | Price | Payments this / last period | All payments | Last payment |
// |---|---|---|---|---|
// | [#1 Weekly \*coffee\* for&#32;g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 \$5](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:plan/1) | 1 GNOT every week | 0 / 0 | 0 | never |
// | [#2 Demo \| one minute](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:plan/2) | 0.25 GNOT every minute | 0 / 0 | 0 | never |
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("help")
// # How to use Mandate
//
// Every command is for the **onyx-1** test network and uses test GNOT. Replace the words in capitals. Amounts are in ugnot (1 GNOT = 1,000,000 ugnot); periods and times are in seconds and unix seconds.
//
// ## For creators
//
// 1. Publish a plan with your own key: a title (one line, at most 80 characters, no invisible formatting characters: direction controls and zero-width characters, the joiner included, are refused, so emoji joined into one, such as families, cannot be used), the amount (at least 0.1 GNOT) and the period (60 seconds to 30 days). Plans cannot be changed.
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Offer -args "TITLE" -args 1000000 -args 604800 -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// 2. Make a separate key for collecting (`gnokey add COLLECTOR_KEY`) and publish its public key (the `gpub1...` value `gnokey list` shows), signed with your own key. **Never send coins to the collector key's address**, not even for fees (the supporter pays every fee): an address that has received coins is an account, and the chain refuses to create a session for it, so nobody new could subscribe. Anyone can do this to a published key with a 1 ugnot send, and a realm can even make the address an account that holds nothing. In most cases the plan page then says so; in every case supporters get the chain error `session key address collides with existing account` when they create the session, and the collector script warns. Then the key can no longer be used for new sessions: make a new key and publish it (this command again). New supporters then use the new key, and existing mandates keep being collected with the old one: run one collector per key. `Subscribe` accepts any session key you hand out, so you can also give supporters a fresh key privately:
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func SetCollectorKey -args GPUB_OF_COLLECTOR_KEY -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// 3. Collect each payment when it is due, signed with the collector key on behalf of the supporter. Only the exact price is accepted, at most once per period. The fee counts against the supporter's fee allowance, so keep it small. The command below uses today's minimum fee on onyx-1 (1 ugnot per 1,000 gas); when the chain raises its gas price, raise `-gas-fee` with it (`gnokey query auth/gasprice`), within the allowance. The collector script does this itself:
//
// ```
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Pull -send AMOUNTugnot -master SUPPORTER_ADDRESS -gas-fee 20000ugnot -gas-wanted 20000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 COLLECTOR_KEY
// ```
//
// The repository has a collector script that finds what is due through free queries and pulls it.
//
// ## For supporters
//
// Open a plan's page: it shows the two exact commands, with the creator's collector key, the spend limit (price plus 0.1 GNOT for fees) and the period filled in. The general form:
//
// ```
// gnokey maketx session create -pubkey COLLECTOR_GPUB -allow-paths vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -spend-limit PRICE_PLUS_100000ugnot -spend-period PERIOD_SECONDS -expires-at UNIX_TIME -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Subscribe -args PLAN_ID -args COLLECTOR_ADDRESS -args UNIX_TIME -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// Use the same UNIX_TIME for both, at most 366 days ahead. The session must allow exactly `vm/exec:gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate` and nothing else, or Pull refuses it. PERIOD_SECONDS is the plan's period, at most 30 days (the chain's limit on a spend period). You can support one plan of each creator at a time: all of a creator's plans are collected by one key, and the chain allows one session per key.
//
// ### Stop a mandate
//
// Do both, with your own key. Your page (`/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate:payer/YOUR_ADDRESS`) shows them filled in.
//
// ```
// gnokey maketx session revoke -pubkey COLLECTOR_GPUB -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// gnokey maketx call -pkgpath gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate -func Cancel -args YOUR_ADDRESS -args COLLECTOR_ADDRESS -gas-fee 100000ugnot -gas-wanted 60000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 YOUR_KEY
// ```
//
// ## Checking a supporter (free)
//
// To decide whether to deliver something to a supporter, ask how long their latest payment covers them: `PaidThrough` returns a unix time (0 if they never paid); deliver while now is before it. Paid time stays the supporter's after a cancel or an expiry. Do not rely on a mandate merely existing: anyone can record one without paying. A realm cannot see a session revoked on chain either, but a revoked supporter stops paying, so `PaidThrough` stops moving and runs out within one period. It runs out at the due time and moves on only when the creator's collector takes the next payment, so allow a grace equal to how often the collector runs (an hour, say) before treating someone as lapsed. The second query shows the chain's view of the session.
//
// ```
// gnokey query vm/qeval -data 'gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate.PaidThrough(address("PAYER"), PLAN_ID)' -remote https://rpc.onyx.testnets.gno.land:443
// gnokey query auth/accounts/PAYER/session/COLLECTOR_ADDRESS -remote https://rpc.onyx.testnets.gno.land:443
// ```
//
// ## Rules the realm enforces
//
// - Pull: signed with a session key as a direct call; the session allows exactly this realm; a recorded, active mandate for that payer and key; exactly the price in ugnot; at most once per period (the next one is due one period after the last); not after the expiry.
// - Every other function refuses session keys and coins.
// - The first payment can be pulled as soon as the mandate is recorded (billing in advance). A missed period is never collected later.
// - A wallet can have at most 16 sessions, so at most 16 mandates at a time.
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
//
// ==== Render("nope")
// # Not found
//
// There is no such page. [Back to Mandate](/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/mandate)
//
// ---
//
// Built on [gno.land](https://gno.land) · source code: [github.com/elangrr/mandate](https://github.com/elangrr/mandate)
