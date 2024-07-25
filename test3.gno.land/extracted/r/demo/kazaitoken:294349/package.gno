package kazaitoken

import (
  "std"
  "strings"

  "gno.land/r/demo/users"
  "gno.land/p/demo/ufmt"
  "gno.land/p/demo/grc/grc20"
)

var (
  kazaitoken *grc20.AdminToken
  admin std.Address = "g1v664qx78zhv2edtx6ypdylfpafrqjz8g2rlaea"
)

func init() {
  kazaitoken = grc20.NewAdminToken("kazaiToken", "KAZ", 6)
  kazaitoken.Mint(admin, 100000000)
}

func TotalSupply() uint64 {
  return kazaitoken.TotalSupply()
}