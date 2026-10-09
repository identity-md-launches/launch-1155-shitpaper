Vendored test-only dependencies (no remappings; relative imports).

- v4-core/src: Uniswap v4-core at commit 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 (src/test removed; licences in v4-core/licenses).
  Only change: ProtocolFees.sol imports Owned from ../../solmate/src/auth/Owned.sol instead of the solmate remapping.
- solmate/src/auth/Owned.sol: transmissions11/solmate main, MIT (AGPL-3.0-only is the solmate repo licence; Owned.sol is marked MIT in its SPDX header).

These exist so the test suite can run a real PoolManager offline. Nothing here is deployed.
