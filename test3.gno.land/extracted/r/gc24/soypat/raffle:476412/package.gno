package raffle

import (
  "gno.land/r/gc24/raffle"
)

const (
  code = "CyH0GyhYsx"
  user = "soypat"  
)

func init() {
  // keyboard's mine c:
  raffle.RegisterCode(code)
  raffle.RegisterUsername(user)
}
