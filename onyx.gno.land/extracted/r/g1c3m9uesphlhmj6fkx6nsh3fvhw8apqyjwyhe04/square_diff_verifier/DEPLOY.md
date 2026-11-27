# Deployment Instructions (gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/square_diff_verifier)

1. Ensure Veil Core is deployed at `gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/groth16/v2`.
2. Run local tests:
   ```bash
   gno test -v .
   ```
3. Deploy to Onyx (`onyx-1`):
   ```bash
   gnokey maketx addpkg \
     -pkgdir "C:\Users\Nishanth\.gemini\antigravity\brain\df47824d-2f9b-4fcb-a89b-67fa8c22a4e7\scratch\onboarding_e2e\square_diff_verifier" \
     -pkgpath "gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/square_diff_verifier" \
     -gas-fee 1000000ugnot -gas-wanted 20000000 -max-deposit 50000000ugnot \
     -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <key-name>
   ```
