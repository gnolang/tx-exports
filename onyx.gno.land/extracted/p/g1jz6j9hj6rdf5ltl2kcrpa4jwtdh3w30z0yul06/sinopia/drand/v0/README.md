# drand evmnet verifier — unmodified copy of gnolang/gno#6268 `p/drand/v0`

This package is a **verbatim copy** of `examples/gno.land/p/drand/v0` from the open pull request
[gnolang/gno#6268](https://github.com/gnolang/gno/pull/6268) ("drand randomness"), head commit
`31c3e018dac4053f7cd538be515e5c8570e657a1`, author **albttx**. Every `.gno` file is
byte-identical to that commit; the only change is the `module` line in `gnomod.toml`, which places it in
Sinopia's namespace (`gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/drand/v0`) because the
canonical path `gno.land/p/drand/v0` is not deployed on any chain yet.

SHA-256 of the copied files (first 16 hex): `drand.gno` e678c1c8ecbed7d0, `field.gno` 6a0e9007a99eca98,
`hash.gno` a652d727eab9d3df, `drand_test.gno` 25ad6f64ab5d6def, `vectors_test.gno` 9db945dbfc98dc55.

It is kept only until #6268 lands and `gno.land/p/drand/v0` is deployed upstream; Sinopia's provider then
switches to the canonical import (a new provider realm path + `randomness.add`). Do not edit the logic here:
fixes go upstream, and the copy is refreshed byte-for-byte.

What it does: verifies drand **evmnet** beacons (BN254, scheme `bls-bn254-unchained-on-g1`, 3 s rounds) in
pure Gno on the `crypto/bn254`, `keccak256`, `modexp` natives that gno v1.7.0 ships; `Randomness = sha256(sig)`.
Used by `realms/r/randomness/drand`.

## License

Copyright (C) 2025 NewTendermint, LLC (the gno repository; this code was contributed to it by albttx).

This program is free software: you can redistribute it and/or modify it under the terms of the GNO Network
General Public License as published by NewTendermint, LLC, either version 6 of the License, or (at your option)
any later version published by NewTendermint, LLC. It is distributed in the hope that it will be useful, but
is provided as-is and WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNO Network General Public License for more details.

The full license text, including its Additional Terms (Strong Attribution), is in `LICENSE.md` next to this
file (copied unchanged from the gno repository at the same commit) and at <https://gno.land/license>.
On chain the package carries this README (notice + link); `LICENSE.md` (38 KB) stays in the repository to
avoid ~3.8 GNOT of storage deposit for a text that is published at the URL above.
