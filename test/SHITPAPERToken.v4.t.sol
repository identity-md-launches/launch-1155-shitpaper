// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SHITPAPERToken} from "../src/SHITPAPERToken.sol";

import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "./vendor/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";

/// @dev The pair token (IMD), a plain ERC-20 placed at IMD's mainnet address so the pool sorts its
/// currencies the way mainnet will.
contract MockIMD {
    string public constant name = "IdentityMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for ProjectFactory: deploys the token (so the token mints to it), answers
/// distributorOf(launchNumber), and seeds the pool single-sided through the PoolManager's unlock.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public manager;
    mapping(uint64 => address) public distributorOf;

    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function deployToken(address poolManager, uint64 launchNumber) external returns (SHITPAPERToken) {
        return new SHITPAPERToken(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(SHITPAPERToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(IPoolManager manager_, PoolKey calldata key, uint160 price) external returns (int24) {
        return manager_.initialize(key, price);
    }

    function seed(IPoolManager manager_, Seed calldata seed_) external returns (BalanceDelta) {
        manager = manager_;
        return abi.decode(manager_.unlock(abi.encode(seed_)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        Seed memory s = abi.decode(data, (Seed));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            s.key, ModifyLiquidityParams(s.tickLower, s.tickUpper, int256(uint256(s.liquidity)), bytes32(0)), ""
        );
        Settle.pay(manager, s.key.currency0, delta.amount0());
        Settle.pay(manager, s.key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

library Settle {
    /// @dev Pays a negative delta with sync / transfer / settle; a positive one would be a take.
    function pay(IPoolManager manager, Currency currency, int128 amount) internal {
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        manager.sync(currency);
        (bool ok,) =
            Currency.unwrap(currency).call(abi.encodeWithSignature("transfer(address,uint256)", address(manager), owed));
        require(ok, "pay failed");
        manager.settle();
    }

    /// @dev Takes a positive delta out of the manager to `to`.
    function take(IPoolManager manager, Currency currency, int128 amount, address to) internal {
        if (amount <= 0) return;
        manager.take(currency, to, uint256(uint128(amount)));
    }
}

/// @dev An ordinary trader: nothing the token has any reason to exempt. Settles what it owes and
/// takes what it is owed to `recipient` (itself by default).
contract Trader is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;
    address public recipient;

    constructor(IPoolManager manager_) {
        manager = manager_;
        recipient = address(this);
    }

    function setRecipient(address to) external {
        recipient = to;
    }

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        Settle.pay(manager, key.currency0, delta.amount0());
        Settle.pay(manager, key.currency1, delta.amount1());
        Settle.take(manager, key.currency0, delta.amount0(), recipient);
        Settle.take(manager, key.currency1, delta.amount1(), recipient);
        return abi.encode(delta);
    }
}

/// @notice The launch as the factory performs it, against a real Uniswap v4 PoolManager built in
/// place at its mainnet address: seed single-sided, then ordinary traders buy and sell through
/// swaps while the pool charges its 1.25% LP fee and the token charges its 3% buy fee.
contract SHITPAPERTokenV4Test is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 947;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_TOKEN0 = 125_270_724_187_523_965_593_206_900; // launch.json initialPrice
    uint256 constant Q96 = 1 << 96;

    LaunchFactory factory;
    SHITPAPERToken token;
    IPoolManager manager;
    MockIMD imd;
    PoolKey key;
    bool tokenIsZero;
    uint256 seeded;

    function setUp() public {
        // A working PoolManager at the mainnet address: v4's manager records the address it was built
        // at, so it is constructed there rather than copied there.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        require(built && runtime.length > 0, "pool manager could not be built in place");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);

        vm.etch(IMD, address(new MockIMD()).code);
        imd = MockIMD(IMD);

        factory = new LaunchFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH);
        assertEq(token.balanceOf(address(factory)), SUPPLY);

        // The launch flow: distributor first, then the pool, then the remainder to 0x...dead.
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);

        tokenIsZero = address(token) < IMD;
        (Currency c0, Currency c1) = tokenIsZero
            ? (Currency.wrap(address(token)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(0)));

        uint160 price = tokenIsZero ? SQRT_PRICE_TOKEN0 : uint160((uint256(1) << 192) / SQRT_PRICE_TOKEN0);
        int24 tick = factory.initialize(manager, key, price);

        // Single-sided seed of (just under) 90% of the supply, entirely on the token's side.
        uint256 allowed = SUPPLY * 9 / 10;
        uint256 amount = allowed - 1e18; // margin for the manager's round-up on the amount owed
        int24 lower;
        int24 upper;
        uint128 liquidity;
        if (tokenIsZero) {
            lower = (tick / TICK_SPACING) * TICK_SPACING;
            if (lower <= tick) lower += TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
            uint160 sa = TickMath.getSqrtPriceAtTick(lower);
            uint160 sb = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(FullMath.mulDiv(amount, FullMath.mulDiv(sa, sb, Q96), sb - sa));
        } else {
            upper = (tick / TICK_SPACING) * TICK_SPACING;
            if (upper > tick) upper -= TICK_SPACING;
            lower = TickMath.minUsableTick(TICK_SPACING);
            uint160 sa = TickMath.getSqrtPriceAtTick(lower);
            uint160 sb = TickMath.getSqrtPriceAtTick(upper);
            liquidity = uint128(FullMath.mulDiv(amount, Q96, sb - sa));
        }
        uint256 before = token.balanceOf(address(factory));
        BalanceDelta delta = factory.seed(manager, LaunchFactory.Seed(key, lower, upper, liquidity));
        seeded = before - token.balanceOf(address(factory));
        assertGt(seeded, 0, "the seed took nothing");
        assertLe(seeded, allowed, "the seed took more than the pool share");
        // Single-sided: the IMD leg of the seed is exactly zero.
        assertEq(tokenIsZero ? delta.amount1() : delta.amount0(), 0, "seed was not single-sided");
        assertEq(uint256(uint128(-(tokenIsZero ? delta.amount0() : delta.amount1()))), seeded);

        factory.move(token, DEAD, token.balanceOf(address(factory)));
        assertEq(token.balanceOf(address(factory)), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    function _newTrader(uint256 imdFunds) internal returns (Trader t) {
        t = new Trader(manager);
        imd.mint(address(t), imdFunds);
    }

    /// @dev Buys with exactly `imdIn` IMD. Returns the gross token amount the pool sent out.
    function _buyExactIn(Trader t, uint256 imdIn) internal returns (uint256 gross) {
        BalanceDelta d = t.swap(key, !tokenIsZero, -int256(imdIn));
        int128 tokenDelta = tokenIsZero ? d.amount0() : d.amount1();
        assertGt(tokenDelta, 0, "buy delivered nothing");
        gross = uint256(uint128(tokenDelta));
    }

    /// @dev Buys exactly `tokensOut` gross tokens from the pool.
    function _buyExactOut(Trader t, uint256 tokensOut) internal returns (uint256 imdPaid) {
        BalanceDelta d = t.swap(key, !tokenIsZero, int256(tokensOut));
        int128 tokenDelta = tokenIsZero ? d.amount0() : d.amount1();
        assertEq(uint256(uint128(tokenDelta)), tokensOut, "exact output was not honoured");
        int128 imdDelta = tokenIsZero ? d.amount1() : d.amount0();
        imdPaid = uint256(uint128(-imdDelta));
    }

    /// @dev Sells exactly `tokensIn` tokens. Returns the IMD received.
    function _sellExactIn(Trader t, uint256 tokensIn) internal returns (uint256 imdOut) {
        BalanceDelta d = t.swap(key, tokenIsZero, -int256(tokensIn));
        int128 imdDelta = tokenIsZero ? d.amount1() : d.amount0();
        assertGt(imdDelta, 0, "sell returned nothing");
        imdOut = uint256(uint128(imdDelta));
    }

    // ----------------------------------------------------------------------------------------
    // Seed
    // ----------------------------------------------------------------------------------------

    function test_seedSettlesExactlyAndPaysNoFee() public view {
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "the manager holds something other than the seed");
        assertEq(token.balanceOf(address(token)), 0, "the seed paid a fee");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.eligibleSupply(), 0, "something eligible is left after the launch flow");
        assertEq(token.distributor(), DISTRIBUTOR);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        assertEq(token.balanceOf(DEAD), SUPPLY - SUPPLY / 10 - seeded);
    }

    // ----------------------------------------------------------------------------------------
    // Buys
    // ----------------------------------------------------------------------------------------

    function test_buyThroughSwapPaysThreePercentToTheContract() public {
        Trader alice = _newTrader(10e18);
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);

        vm.recordLogs();
        uint256 gross = _buyExactIn(alice, 1e18);
        uint256 fee = gross * 300 / 10_000;

        assertEq(token.balanceOf(address(alice)), gross - fee, "buyer did not receive 97%");
        assertEq(token.balanceOf(address(token)), fee, "the contract did not keep 3%");
        assertEq(
            token.balanceOf(POOL_MANAGER),
            pmBefore - gross,
            "the manager's balance moved by something other than the swap"
        );
        assertEq(imd.balanceOf(address(alice)), 9e18, "exact input was not honoured");
        // Nobody was eligible yet: the fee waits for the next distribution.
        assertEq(token.pendingDistribution(), fee);
        assertEq(token.claimableDividendOf(address(alice)), 0, "the buyer shared in its own fee");
        assertEq(token.eligibleSupply(), gross - fee);

        // The buy emitted the fee event with the gross amount.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == SHITPAPERToken.BuyFeeCollected.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(alice));
                (uint256 g, uint256 f) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(g, gross);
                assertEq(f, fee);
                seen = true;
            }
        }
        assertTrue(seen, "BuyFeeCollected was not emitted");
    }

    function test_exactOutputBuyDeliversNetOfFee() public {
        Trader alice = _newTrader(1_000e18);
        uint256 want = 1_000_000e18;
        _buyExactOut(alice, want);
        assertEq(token.balanceOf(address(alice)), want - want * 300 / 10_000, "exact-output buyer got the gross amount");
        assertEq(token.balanceOf(address(token)), want * 300 / 10_000);
    }

    function test_buyTakenToAnotherWalletTaxesTheRecipient() public {
        Trader alice = _newTrader(10e18);
        address bob = address(0xB0B);
        alice.setRecipient(bob);
        uint256 gross = _buyExactIn(alice, 1e18);
        assertEq(token.balanceOf(bob), gross - gross * 300 / 10_000);
        assertEq(token.balanceOf(address(alice)), 0);
    }

    function test_secondBuyDistributesPendingAndNewFeeToFirstBuyer() public {
        Trader alice = _newTrader(10e18);
        Trader bob = _newTrader(10e18);
        uint256 g1 = _buyExactIn(alice, 1e18);
        uint256 f1 = g1 * 300 / 10_000;
        uint256 g2 = _buyExactIn(bob, 2e18);
        uint256 f2 = g2 * 300 / 10_000;

        assertEq(token.pendingDistribution(), 0);
        assertEq(token.totalDividendsDistributed(), f1 + f2);
        assertApproxEqAbs(
            token.claimableDividendOf(address(alice)), f1 + f2, 1, "sole holder did not get the whole fee"
        );
        assertEq(token.claimableDividendOf(address(bob)), 0, "a buyer shared in its own fee");
        assertEq(token.balanceOf(address(token)), f1 + f2);
    }

    // ----------------------------------------------------------------------------------------
    // Sells: settlement must balance exactly or unlock reverts with CurrencyNotSettled
    // ----------------------------------------------------------------------------------------

    function test_sellThroughSwapIsNotTaxedAndSettles() public {
        Trader alice = _newTrader(10e18);
        uint256 gross = _buyExactIn(alice, 1e18);
        uint256 held = token.balanceOf(address(alice));
        assertEq(held, gross - gross * 300 / 10_000);
        uint256 contractBefore = token.balanceOf(address(token));
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        uint256 imdBefore = imd.balanceOf(address(alice));

        uint256 imdOut = _sellExactIn(alice, held);

        assertEq(token.balanceOf(address(alice)), 0, "the trader could not sell everything");
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore + held, "the sell arrived short at the manager");
        assertEq(token.balanceOf(address(token)), contractBefore, "a sell paid a fee");
        assertEq(imd.balanceOf(address(alice)), imdBefore + imdOut);
        assertGt(imdOut, 0);
        // Round trip through a 1.25% pool and a 3% buy fee loses value: never a free lunch.
        assertLt(imd.balanceOf(address(alice)), 10e18, "a round trip minted value");
    }

    function test_claimedDividendsCanBeSoldWhole() public {
        Trader alice = _newTrader(10e18);
        Trader bob = _newTrader(10e18);
        _buyExactIn(alice, 1e18);
        _buyExactIn(bob, 3e18);

        uint256 claimable = token.claimableDividendOf(address(alice));
        assertGt(claimable, 0);
        uint256 paid = token.claimFor(address(alice));
        assertEq(paid, claimable);
        uint256 held = token.balanceOf(address(alice));
        _sellExactIn(alice, held);
        assertEq(token.balanceOf(address(alice)), 0);
        // Alice is out; Bob now holds the only eligible balance and keeps earning.
        assertEq(token.eligibleSupply(), token.balanceOf(address(bob)));
    }

    function test_poolKeepsWorkingAcrossManyRoundTrips() public {
        Trader[3] memory traders = [_newTrader(100e18), _newTrader(100e18), _newTrader(100e18)];
        for (uint256 round; round < 4; ++round) {
            for (uint256 i; i < traders.length; ++i) {
                _buyExactIn(traders[i], (i + 1) * 1e18);
            }
            for (uint256 i; i < traders.length; ++i) {
                uint256 held = token.balanceOf(address(traders[i]));
                _sellExactIn(traders[i], held / 2);
            }
        }
        // Everyone who holds can still be paid, and the contract covers what it owes.
        uint256 owed = token.pendingDistribution();
        for (uint256 i; i < traders.length; ++i) {
            owed += token.claimableDividendOf(address(traders[i]));
        }
        assertGe(token.balanceOf(address(token)), owed, "the contract owes more than it holds");
        for (uint256 i; i < traders.length; ++i) {
            token.claimFor(address(traders[i]));
        }
        assertEq(token.totalSupply(), SUPPLY);
        // The pool is still tradable both ways after all of it.
        _buyExactIn(traders[0], 1e18);
        _sellExactIn(traders[0], token.balanceOf(address(traders[0])));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_buyThenSellSettlesForAnyAmount(uint256 imdIn) public {
        imdIn = bound(imdIn, 1e12, 500e18);
        Trader alice = _newTrader(imdIn);
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        uint256 gross = _buyExactIn(alice, imdIn);
        uint256 fee = gross * 300 / 10_000;
        assertEq(token.balanceOf(address(alice)), gross - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore - gross);
        if (gross - fee > 0) {
            _sellExactIn(alice, gross - fee);
            assertEq(token.balanceOf(address(alice)), 0);
            assertEq(token.balanceOf(POOL_MANAGER), pmBefore - fee);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}

