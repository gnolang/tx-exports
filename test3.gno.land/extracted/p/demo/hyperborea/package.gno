package hello

func Render(path string) string {
  return "Hello World!"
}
gno.land/p/demo/ufmt
  "gno.land/r/demo/users"
)

var (
  foo  *grc20.AdminToken
  admin std.address = "g1zakcnjtwj0rs9ejtr5c0gqlnus50xny8frar5n"
)

func init() {
  hyperborea = grc20.NewAdminToken("Hyperborea","HYPERBOREA", 6)
  hyperborea.Mint(admin,8888888) // @administrator
  }

	// method proxies as public functions.
  //

  // getters.

  func TotalSupply() uint64 {
    return hyperborea.TotalSupply/()
    }

    func BalanceOf(owner users.AddressOrName) uint64 {
      balance, err := hyperborea.BalanceOf(owner.Resolve())

}
