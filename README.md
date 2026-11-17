# CF-MOR-1 PoC — DistributorV2 counts a donation as yield (Morpheus)

A plain transfer of the yield token straight to DistributorV2 is counted as
yield, so `distributeRewards` mints extra MOR to the pool and the donor's share
of it can be claimed through the real LayerZero path.

This mechanism was described before, in the Code4rena Capital V2 report
(August 2025), against the code from before the fixes. These tests run against
the code that is live today, after those fixes.

Two test batteries:

- `Mor1Deep.t.sol` — the full battery: donation counted as yield on the wBTC
  (Aave) pool, tuning, sequencing, and the claim leg end to end
  (`MintMessageSent` of 1,402.95 MOR through the real LayerZero endpoint).
  Fork pin: Ethereum block 26435255.
- `MorFixGap.t.sol` — the fix-history battery: the shortfall direction the
  team fixed (balance under the recorded balance — no revert, zero accrual)
  and the exact 0.0011 stETH donation from the 2025 report on the live code
  (pool accrual 0 -> 71.35 MOR). Fork pin: Ethereum block 26436500.

No setup needed: forge-std v1.17.0 (the version these tests were validated
with) is vendored under `lib-forge-std/src/`, which is where foundry.toml maps
`forge-std/` to. Just clone and run:

  forge test

Expected: Mor1Deep 21 passed, 0 failed; MorFixGap 3 passed, 0 failed.
Fork of Ethereum mainnet, RPC https://ethereum.publicnode.com, hardcoded in
the test sources (Mor1Deep also accepts the MOR_RPC_URL override).
Fork/simulation only — no mainnet transactions.
