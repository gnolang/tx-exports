package huecoco

import (
    "gno.land/p/demo/ufmt"
    hueco "gno.land/p/marbella/hueco/v2"
)

func Echo(v string) string {
    return ufmt.Sprintf("echo: %s", hueco.Echo(v))
}