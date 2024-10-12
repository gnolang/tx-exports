package selfcall

import "std"

var admin std.Address

func init() {
  admin = std.GetOrigCaller()
}

func OnlyAdmin() string {
  res := innerCall()
  return "OnlyAdmin__" + res  + "__" + boolToStr(std.IsOriginCall())
}


func CallOnlySelf() string {
  res := innerCall()
  return "CallOnlySelf" + res + "__" + boolToStr(std.IsOriginCall())
}

func OnlySelf() string {
  res := innerCall()
  return "OnlySelf" + res + "__" + boolToStr(std.IsOriginCall())
}

func innerCall() string {
  return makeReturn()
}


func makeReturn() string {
  origCallerStr := std.GetOrigCaller().String()

  prev := std.PrevRealm()
  prevAddrStr := prev.Addr().String()
  prevPkgPath := prev.PkgPath()

  curr := std.CurrentRealm()
  currAddrStr := curr.Addr().String()
  currPkgPath := curr.PkgPath()


  origPkgAddrStr := std.GetOrigPkgAddr().String()

  return origCallerStr + "__" + prevAddrStr + "__" + prevPkgPath + "__" + currAddrStr + "__" + currPkgPath + "__" + origPkgAddrStr
}

func boolToStr(v bool) string {
  if v {
    return "true"
  }

  return "false"
}