# tx exports

This repo serves the purpose of archiving data from testnets.

Currently, it contains the following:
- Raw transaction data from
  - `test4.gno.land`
  - `test3.gno.land`
  - `test2.gno.land`
  - `test1.gno.land`
  - `staging.gno.land`
- Gno code extracted from raw transactions in the respective `extracted` folders
- A Go program used to extract Gno code from raw transactions; located in `extractor/`

This repo has a Github Action that fetches transaction data and runs the extractor once every 24 hours.
