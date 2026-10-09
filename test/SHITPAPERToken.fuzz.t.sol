// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SHITPAPERToken} from "../src/SHITPAPERToken.sol";
import {MockFactory} from "./SHITPAPERToken.t.sol";

/// @notice Property tests over the fee and dividend arithmetic at arbitrary amounts.
contract SHITPAPERTokenFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 947;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    MockFactory factory;
    SHITPAPERToken token;

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
    }

    /// @dev Hands `a` to Alice and `b` to Bob straight from the factory (untaxed), then seeds the
    /// pool with everything else, so the eligible supply is exactly a + b.
    function _holders(uint256 a, uint256 b) internal {
        if (a > 0) factory.move(token, ALICE, a);
        if (b > 0) factory.move(token, BOB, b);
        factory.move(token, POOL_MANAGER, token.balanceOf(address(factory)));
        assertEq(token.eligibleSupply(), a + b);
    }

    function _buy(address buyer, uint256 gross) internal returns (uint256 fee) {
        vm.prank(POOL_MANAGER);
        token.transfer(buyer, gross);
        return gross * 300 / 10_000;
    }

    // ----------------------------------------------------------------------------------------
    // Fee arithmetic
    // ----------------------------------------------------------------------------------------

    function testFuzz_buyFeeIsExactlyThreePercentFloored(uint256 gross) public {
        gross = bound(gross, 0, SUPPLY * 9 / 10);
        _holders(0, 0);
        uint256 fee = gross * 300 / 10_000;
        assertEq(token.buyFeeOn(gross), fee);
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        _buy(CAROL, gross);
        assertEq(token.balanceOf(CAROL), gross - fee, "buyer net");
        assertEq(token.balanceOf(address(token)), fee, "contract fee");
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore - gross, "manager debit");
        assertEq(token.totalSupply(), SUPPLY);
        assertLe(fee * 10_000, gross * 300, "fee above 3%");
        assertLe(gross * 300 - fee * 10_000, 9_999, "fee rounded by more than one unit");
    }

    /// @dev Below 34 wei the 3% rounds to nothing. Documented rounding, not a loophole worth gas.
    function testFuzz_dustBuysBelowThirtyFourWeiPayNothing(uint256 gross) public {
        gross = bound(gross, 0, 33);
        _holders(0, 0);
        _buy(CAROL, gross);
        assertEq(token.balanceOf(CAROL), gross);
        assertEq(token.balanceOf(address(token)), 0);
        if (gross > 0) assertEq(token.buyFeeOn(34), 1);
    }

    function testFuzz_sellsAndWalletTransfersPayNothing(uint256 a, uint256 x, uint256 y) public {
        a = bound(a, 1, SUPPLY / 2);
        x = bound(x, 0, a);
        y = bound(y, 0, a - x);
        _holders(a, 0);
        vm.prank(ALICE);
        token.transfer(BOB, x);
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, y);
        assertEq(token.balanceOf(BOB), x);
        assertEq(token.balanceOf(ALICE), a - x - y);
        assertEq(token.balanceOf(address(token)), 0, "a non-buy paid a fee");
        assertEq(token.eligibleSupply(), a - y, "eligible supply drifted");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromThePoolManagerIsTaxedWhoeverSpends(uint256 gross, address spender) public {
        gross = bound(gross, 34, SUPPLY / 2);
        vm.assume(spender != address(0) && spender != POOL_MANAGER);
        _holders(0, 0);
        vm.prank(POOL_MANAGER);
        token.approve(spender, gross);
        vm.prank(spender);
        token.transferFrom(POOL_MANAGER, CAROL, gross);
        assertEq(token.balanceOf(CAROL), gross - gross * 300 / 10_000, "the fee is keyed on from, not msg.sender");
        assertEq(token.allowance(POOL_MANAGER, spender), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Distribution
    // ----------------------------------------------------------------------------------------

    function testFuzz_feeIsSplitProRataOnPreBuyBalances(uint256 a, uint256 b, uint256 gross) public {
        a = bound(a, 1, SUPPLY / 4);
        b = bound(b, 1, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        _holders(a, b);
        uint256 fee = _buy(CAROL, gross);

        uint256 expA = fee * a / (a + b);
        uint256 expB = fee * b / (a + b);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), expA, 1, "Alice share");
        assertApproxEqAbs(token.claimableDividendOf(BOB), expB, 1, "Bob share");
        assertEq(token.claimableDividendOf(CAROL), 0, "the buyer shared in its own fee");
        uint256 sum = token.claimableDividendOf(ALICE) + token.claimableDividendOf(BOB);
        assertLe(sum, fee, "more was credited than collected");
        assertLe(fee - sum, 2, "more than rounding dust is stranded");
        assertEq(token.totalDividendsDistributed(), fee);
        assertEq(token.pendingDistribution(), 0);
        assertEq(token.eligibleSupply(), a + b + gross - fee);
    }

    function testFuzz_buyerEarnsOnPreBuyBalanceOnly(uint256 a, uint256 b, uint256 gross) public {
        a = bound(a, 1, SUPPLY / 4);
        b = bound(b, 1, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        _holders(a, b);
        uint256 fee = _buy(ALICE, gross); // Alice buys while already holding a
        uint256 onPreBalance = fee * a / (a + b);
        uint256 onPostBalance = fee * (a + gross - fee) / (a + b + gross - fee);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), onPreBalance, 1);
        if (onPostBalance > onPreBalance + 2) {
            assertLt(token.claimableDividendOf(ALICE), onPostBalance, "the buyer's net amount earned from its own fee");
        }
    }

    function testFuzz_pendingFeeIsPaidWithTheNextDistribution(uint256 g1, uint256 g2) public {
        g1 = bound(g1, 34, SUPPLY / 4);
        g2 = bound(g2, 34, SUPPLY / 4);
        _holders(0, 0);
        uint256 f1 = _buy(ALICE, g1);
        assertEq(token.pendingDistribution(), f1, "fee with no eligible holder was not parked");
        assertEq(token.totalDividendsDistributed(), 0);
        uint256 f2 = _buy(BOB, g2);
        assertEq(token.pendingDistribution(), 0);
        assertEq(token.totalDividendsDistributed(), f1 + f2);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), f1 + f2, 1);
        assertEq(token.claimableDividendOf(BOB), 0);
    }

    function testFuzz_movingTokensMovesFutureNotPastDividends(uint256 a, uint256 gross, uint256 moved) public {
        a = bound(a, 2, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        moved = bound(moved, 1, a);
        _holders(a, 0);
        uint256 f1 = _buy(CAROL, gross);
        uint256 aliceBefore = token.claimableDividendOf(ALICE);
        assertApproxEqAbs(aliceBefore, f1, 1);

        vm.prank(ALICE);
        token.transfer(BOB, moved);
        assertEq(token.claimableDividendOf(ALICE), aliceBefore, "a transfer changed accrued dividends");
        assertEq(token.claimableDividendOf(BOB), 0, "dividends travelled with the tokens");

        uint256 f2 = _buy(address(0xF00D), gross);
        uint256 eligible = a + gross - f1;
        assertApproxEqAbs(token.claimableDividendOf(BOB), f2 * moved / eligible, 1);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), aliceBefore + f2 * (a - moved) / eligible, 1);
    }

    // ----------------------------------------------------------------------------------------
    // Claims
    // ----------------------------------------------------------------------------------------

    function testFuzz_claimPaysExactlyClaimableOnceAndContractStaysSolvent(uint256 a, uint256 b, uint256 gross) public {
        a = bound(a, 1, SUPPLY / 4);
        b = bound(b, 1, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        _holders(a, b);
        uint256 fee = _buy(CAROL, gross);

        uint256 claimable = token.claimableDividendOf(ALICE);
        uint256 contractBefore = token.balanceOf(address(token));
        vm.prank(ALICE);
        uint256 paid = token.claim();
        assertEq(paid, claimable);
        assertEq(token.balanceOf(ALICE), a + claimable);
        assertEq(token.balanceOf(address(token)), contractBefore - claimable);
        assertEq(token.claimableDividendOf(ALICE), 0);
        assertEq(token.eligibleSupply(), a + b + gross - fee + claimable, "a claim did not join the eligible supply");

        vm.prank(ALICE);
        assertEq(token.claim(), 0, "a second claim paid again");
        vm.prank(BOB);
        token.claim();
        // What is left is at most the rounding dust of one distribution.
        assertLe(token.balanceOf(address(token)), 2);
        assertEq(token.totalDividendsClaimed() + token.balanceOf(address(token)), fee);
    }

    function testFuzz_claimForPaysTheHolderNeverTheCaller(address caller, uint256 a, uint256 gross) public {
        a = bound(a, 1, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        vm.assume(caller != ALICE && caller != address(token));
        _holders(a, 0);
        uint256 fee = _buy(CAROL, gross);
        uint256 callerBefore = token.balanceOf(caller);
        vm.prank(caller);
        uint256 paid = token.claimFor(ALICE);
        assertApproxEqAbs(paid, fee, 1);
        assertEq(token.balanceOf(ALICE), a + paid);
        assertEq(token.balanceOf(caller), callerBefore, "the caller was paid");
    }

    function testFuzz_excludedAccountsNeverAccrueAndCannotClaim(uint256 a, uint256 gross) public {
        a = bound(a, 1, SUPPLY / 4);
        gross = bound(gross, 34, SUPPLY / 4);
        _holders(a, 0);
        _buy(CAROL, gross);
        address[4] memory excluded = [POOL_MANAGER, DISTRIBUTOR, DEAD, address(token)];
        for (uint256 i; i < excluded.length; ++i) {
            assertTrue(token.isExcludedFromDividends(excluded[i]));
            assertEq(token.claimableDividendOf(excluded[i]), 0);
            vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, excluded[i]));
            token.claimFor(excluded[i]);
            vm.prank(excluded[i]);
            vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, excluded[i]));
            token.claim();
        }
    }

    // ----------------------------------------------------------------------------------------
    // ERC-20 failure paths
    // ----------------------------------------------------------------------------------------

    function testFuzz_transferAboveBalanceReverts(uint256 a, uint256 x) public {
        a = bound(a, 0, SUPPLY / 4);
        x = bound(x, a + 1, type(uint256).max);
        _holders(a, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, a, x));
        token.transfer(BOB, x);
        // A buy the manager cannot cover reverts too, and charges nothing.
        uint256 pm = token.balanceOf(POOL_MANAGER);
        vm.prank(POOL_MANAGER);
        vm.expectRevert();
        token.transfer(BOB, pm + 1);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFuzz_transferToZeroAddressReverts(uint256 a) public {
        a = bound(a, 1, SUPPLY / 4);
        _holders(a, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), a);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), a);
        assertEq(token.totalSupply(), SUPPLY, "a transfer to zero burnt supply");
    }

    function testFuzz_allowanceIsEnforcedExactly(uint256 a, uint256 allowance, uint256 spend) public {
        a = bound(a, 1, SUPPLY / 4);
        allowance = bound(allowance, 0, a);
        spend = bound(spend, 0, a);
        _holders(a, 0);
        vm.prank(ALICE);
        token.approve(BOB, allowance);
        if (spend > allowance) {
            vm.prank(BOB);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowance, spend)
            );
            token.transferFrom(ALICE, CAROL, spend);
        } else {
            vm.prank(BOB);
            assertTrue(token.transferFrom(ALICE, CAROL, spend));
            assertEq(token.balanceOf(CAROL), spend);
            assertEq(token.allowance(ALICE, BOB), allowance - spend);
        }
    }

    function testFuzz_infiniteAllowanceIsNotDecremented(uint256 a, uint256 spend) public {
        a = bound(a, 1, SUPPLY / 4);
        spend = bound(spend, 0, a);
        _holders(a, 0);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, spend);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }
}
