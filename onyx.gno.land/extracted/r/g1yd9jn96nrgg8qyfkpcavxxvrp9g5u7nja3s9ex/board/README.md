# Assayer board

On-chain registry of Assayer reports. `assayer submit report.json -exec`
calls `Submit`; every report is kept and versioned per package path.

Render routes:

| Path | Page |
|---|---|
| `""` | latest reports, paginated |
| `pkg/<pkgpath>` | version history of one package, with ▲/▼ gas deltas between versions |
| `report/<id>` | one full report: scores, measured cost, findings |
| `badge/<pkgpath>` | one-line summary for a README |

Other realms can gate on a score with `LatestScore(pkgPath)`.

The board follows its own advice: avl trees only, size-capped inputs, a
paginated Render, and a clean `assayer audit`.
