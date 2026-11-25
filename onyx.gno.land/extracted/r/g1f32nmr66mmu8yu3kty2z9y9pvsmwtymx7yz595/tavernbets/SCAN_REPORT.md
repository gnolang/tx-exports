# Scan report — Tavern Bets (Run A, authored code only)

Date: 2026-11-25 (re-run after the Phase 2 refund fix; first run 2026-11-25
Phase 1, same result). Tool versions: OpenGrep 2.0.0, Trivy 0.76.2.
OpenGrep ruleset commit: f1d2b56 (cached 24 Nov 2026).
Trivy DB: UpdatedAt 2026-11-24T13:06:50Z, DownloadedAt 2026-11-24T15:29:25Z.
Target: ~/workspace/gno-tavern/tavernbets/ (4 files: 2 .gno, gnomod.toml, README.md).
No vendored fixtures exist yet, so Run A = the whole project. Run B (full
submission ZIP) does not apply until the repo is packaged.

## OpenGrep (SAST, go ruleset)

- Result: 0 findings (0 ERROR, 0 WARNING).
- Caveat, stated plainly: only 2 rules were evaluated across the 4 files,
  although the go ruleset contains 76 rule files. The `.gno` extension
  limits rule matching, so this scan is weak evidence on its own. The
  stronger signal is `gno lint` (gate G2), which passed with zero findings
  on the same code.

## Trivy (vuln, secret, misconfig, license)

- Vulnerabilities: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW.
- Secrets: 0.
- Misconfigurations: 0. Licenses: no license files found.
- Note: 0 language-specific files detected (a Gno realm has no Go module
  dependencies or lockfiles), 0 config files detected.

## Verdict

Run A meets the own-code targets (0 ERROR / <10 WARNING SAST, 0 CRITICAL /
0 HIGH Trivy, 0 secrets) — with the OpenGrep caveat above. Raw JSON:
tavernbets-opengrep.json, tavernbets-trivy.json (in this directory).
