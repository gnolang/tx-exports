// Fixed-target adapter. No callback, arbitrary call, or recovered panic path.
package memba_dao

import (
    "gno.land/p/samcrew/memba_weighted_host"
    "gno.land/r/samcrew/memba_market_config"
)

func marketState(a memba_weighted_host.MarketAction) memba_weighted_host.MarketState {
    bps := int64(0)
    if a.Kind() == memba_weighted_host.MarketSetFee {
        bps = int64(memba_market_config.GetFeeBPS(string(a.Lane())))
    }
    return memba_weighted_host.MarketState{Admin: memba_market_config.GetAdmin(), PendingAdmin: memba_market_config.GetPendingAdmin(), Treasury: memba_market_config.GetTreasury(), BPS: bps}
}

func ProposeMarketAccept(cur realm) uint64 {
    a := memba_weighted_host.MarketAccept()
    return host.ProposeMarket(a, marketState(a), cur)
}
func ProposeMarketFee(cur realm, lane string, bps int64) uint64 {
    a := memba_weighted_host.MarketFee(memba_weighted_host.MarketLane(lane), bps)
    return host.ProposeMarket(a, marketState(a), cur)
}
func ProposeMarketTreasury(cur realm) uint64 {
    a := marketPolicy.SetTreasury()
    return host.ProposeMarket(a, marketState(a), cur)
}
func ProposeMarketReturn(cur realm) uint64 {
    a := marketPolicy.ReturnAdmin()
    return host.ProposeMarket(a, marketState(a), cur)
}
func ProposeMarketAbortReturn(cur realm) uint64 {
    a := marketPolicy.AbortReturn()
    return host.ProposeMarket(a, marketState(a), cur)
}

func executeMarket(cur realm, id uint64) {
    proposed := host.Proposal(id).MarketAction
    before := marketState(proposed)
    a := host.ConsumeMarket(id, before, cur)
    expected := before
    switch a.Kind() {
    case memba_weighted_host.MarketAcceptAdmin:
        expected.Admin = marketPolicy.DAO()
        expected.PendingAdmin = ""
        memba_market_config.AcceptAdmin(cross(cur))
    case memba_weighted_host.MarketSetFee:
        expected.BPS = a.BPS()
        memba_market_config.SetFeeBPS(cross(cur), string(a.Lane()), a.BPS())
    case memba_weighted_host.MarketSetTreasury:
        expected.Treasury = a.Recipient()
        memba_market_config.SetTreasury(cross(cur), a.Recipient())
    case memba_weighted_host.MarketReturnAdmin:
        expected.PendingAdmin = a.Recipient()
        memba_market_config.TransferAdmin(cross(cur), a.Recipient())
    case memba_weighted_host.MarketAbortReturn:
        expected.PendingAdmin = ""
        memba_market_config.CancelAdminTransfer(cross(cur))
    default:
        panic("unsupported market action")
    }
    // Stage-return deliberately retains DAO admin until the successor accepts
    // separately. A mismatch aborts the entire transaction, including Consume.
    if marketState(a) != expected { panic("market postcondition mismatch") }
}
