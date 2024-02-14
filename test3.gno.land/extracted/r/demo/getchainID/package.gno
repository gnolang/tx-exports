package chaintesters

import ("std")

func GetChainID(path string) string {
  return std.GetChainID()
}

func Render() string {
  return GetChainID()
}
