package getchainid

import ("std")

func GetChainID() string {
  return std.GetChainID()
}

func Render(path string) string {
  return GetChainID()
}
