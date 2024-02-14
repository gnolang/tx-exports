package chainIDtest

import ("std")

func Call(path string) string {
  return std.GetChainID()
}
