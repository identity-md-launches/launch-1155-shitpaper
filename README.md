# shitpaper (SHITPAPER)

A fixed-supply ERC-20 for an IdentityMD custom token launch on Ethereum mainnet, paired with IMD in
a Uniswap v4 pool. A 3% fee on buys is redistributed to holders as dividends. There is no owner, no
admin function, no minting after deployment, no proxy, no `delegatecall` and no `selfdestruct`.

| Item | Value |
| --- | --- |
| Contract | `SHITPAPERToken` (`src/SHITPAPERToken.sol`) |
| Name / symbol / decimals | `shitpaper` / `SHITPAPER` / 18 |
| Total supply | 1,000,000,000 × 1e18 = `1000000000000000000000000000` units, minted once to the deployer |
| Buy fee | 3% (300 bps) on ERC-20 transfers whose `from` is the Uniswap v4 PoolManager |
| Sell / seed / wallet transfers | no fee |
| Pool | IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee 12500 (1.25%), tick spacing 60 |
| PoolManager (Ethereum) | `0x000000000004444c5dc75cB358380D2e3dE08A90` (constructor argument `$poolManager`) |
| Compiler | solc 0.8.26, evm `cancun`, optimizer on, `bytecode_hash = "none"` |

## Layout

- `src/SHITPAPERToken.sol`: the token.
- `test/SHITPAPERToken.t.sol`: smoke tests (deploy, supply, launch flows, buy fee, dividends, claims).
- `lib/openzeppelin-contracts`: the five OpenZeppelin v5.3.0 files the token imports, vendored as plain files.
- `lib/forge-std`: forge-std v1.9.7 `src/`, vendored as plain files (tests only).
- `launch.json`: the launch manifest values for this token.

```
forge build
forge test
forge fmt --check
```

## Constructor

```
constructor(address factory_, address poolManager_, uint64 launchNumber_)
```

All three are supplied by the launch (`$factory`, `$poolManager`, `$launchNumber` in `launch.json`),
stored as immutables and never changeable. The constructor only stores them and mints the whole supply
to `msg.sender`, the launch factory. It calls no other contract, so it deploys on an empty chain.

## How the supply moves at launch

The factory does all distribution. The token never subtracts or sends anything itself.

1. The factory deploys the token and receives the whole supply.
2. The factory registers the launch's Merkle distributor and sends it the swarm's 10%. The token
   reads `factory.distributorOf(launchNumber)` on each transfer until it returns a non-zero address,
   caches that address, and excludes it from dividends from then on.
3. The factory seeds the pool: 90% of the supply moves to the PoolManager. Transfers **to** the
   PoolManager are never taxed, so v4 settlement balances exactly.
4. The remainder goes to `economics.remainderTo` (`0x…dead`, the burn address).

## Fee and dividend mechanics

- **Buy** = ERC-20 transfer with `from == POOL_MANAGER` to anyone other than the PoolManager, the
  token contract, the factory, the burn address or the distributor. The buyer receives 97%; 3%
  moves into the token contract (a `Transfer(PoolManager, token, fee)` event is emitted alongside
  the buyer's `Transfer`).
- **Sell** (`to == POOL_MANAGER`), the pool seed and plain wallet-to-wallet transfers pay nothing.
- **Distribution** happens inside the buy, *before* the buyer's net amount is credited. The fee is
  added to a `rewardPerToken` accumulator against `eligibleSupply` as it stands at that moment, so
  the buyer's pre-buy balance earns its share but the newly bought tokens do not.
- **Eligible supply** is the total supply minus the balances of the excluded accounts: the
  PoolManager, the token contract, `0x…dEaD` and the distributor. If a buy happens while nobody is
  eligible (right after launch everything sits in the pool, the distributor and the burn address),
  the fee waits in `pendingDistribution` and is paid out with the next buy that has eligible holders.
- **Claiming**: `claim()` pays the caller; `claimFor(address)` pays any holder, callable by anyone,
  so dividends owed to a contract that cannot call `claim()` are never locked. Claims are paid from
  the token contract's balance as a normal (untaxed) transfer. Claiming an excluded account reverts
  with `ExcludedFromDividends`.
- **Views**: `claimableDividendOf(address)`, `eligibleSupply()`, `pendingDistribution()`,
  `totalDividendsDistributed()`, `totalDividendsClaimed()`, `isExcludedFromDividends(address)`,
  `isTaxedTransfer(from, to)`, `buyFeeOn(amount)`.

Rounding: per-holder shares are floored, so a few wei per distribution stay in the contract forever.
The contract always holds at least what it owes.

Fees apply only to ERC-20 transfers out of the PoolManager. ERC-6909 claim balances kept inside the
PoolManager never touch the token contract and are out of scope.

## Assumptions and operational notes

- `distributorOf(uint64)` on the factory is the only outside call the token makes. It is a
  `staticcall` made during transfers until the distributor is known; a factory that has no code or
  answers zero simply leaves the distributor unknown, nothing reverts. If the distributor somehow
  received tokens before the factory registered it, those tokens are removed from the eligible
  supply and any dividends it accrued are forfeited when it is first resolved. In the launch flow
  the factory registers it before sending the swarm's share, so this does not happen.
- Tokens sent directly to the token contract by mistake are not redistributed; they stay there.
- Nobody holds any power over the contract after deployment. There is nothing to configure after
  launch and no "After launch" settings.
- The pool opening price is derived by the deployer from `economics.initialMarketCapWei` and the
  deployed currency order; `pool.initialPrice` in `launch.json` is provenance only.
- Tests passing is not an audit. A separate adversarial review and the full test suite (fuzz and
  invariants) are owed by the next contributor. No fork test runs here; the smoke tests simulate the
  PoolManager with `vm.prank` at its mainnet address. During development the token was also driven
  through a real Uniswap v4 `PoolManager` built in place at the mainnet address (seed, buy, dividend
  distribution, claim, sell) in a scratch project that is not part of this delivery; a fork run
  against live mainnet state is still owed.
- If the factory's `distributorOf(uint64)` ever reverted or returned nothing, the distributor would
  stay unknown and would earn dividends like any holder; `claimFor(distributor)` would then pay them
  out to it rather than lock them. The protected launch harness answers `distributorOf(uint64)`.
