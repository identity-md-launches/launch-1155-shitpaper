// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SHITPAPERToken} from "../src/SHITPAPERToken.sol";

/// @dev Stands in for the launch factory: deploys the token (so the token mints to it) and answers
/// distributorOf(launchNumber) the way ProjectFactory does.
contract MockFactory {
    mapping(uint64 => address) public distributorOf;

    function deployToken(address poolManager, uint64 launchNumber) external returns (SHITPAPERToken) {
        return new SHITPAPERToken(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(SHITPAPERToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SHITPAPERTokenTest is Test {
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
    }

    // ----------------------------------------------------------------------------------------
    // Deployment
    // ----------------------------------------------------------------------------------------

    function test_deploy_mintsWholeSupplyToDeployer() public view {
        assertEq(token.name(), "shitpaper");
        assertEq(token.symbol(), "SHITPAPER");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.eligibleSupply(), SUPPLY);
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH);
        assertEq(token.distributor(), address(0));
    }

    function test_deploy_revertsOnZeroAddresses() public {
        vm.expectRevert(SHITPAPERToken.ZeroAddress.selector);
        new SHITPAPERToken(address(0), POOL_MANAGER, LAUNCH);
        vm.expectRevert(SHITPAPERToken.ZeroAddress.selector);
        new SHITPAPERToken(address(factory), address(0), LAUNCH);
    }

    function test_noMintOrAdminSurface() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("burnFrom(address,uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], ALICE, SUPPLY));
            assertFalse(ok, "unexpected admin function");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------
    // Launch flows and plain transfers: never taxed
    // ----------------------------------------------------------------------------------------

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.distributor(), DISTRIBUTOR, "distributor not resolved");
        assertTrue(token.isExcludedFromDividends(DISTRIBUTOR));
        assertEq(token.eligibleSupply(), SUPPLY - swarm);

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, swarm));
        assertEq(token.balanceOf(ALICE), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.eligibleSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_seedAndSellToPoolManagerAreNotTaxed() public {
        uint256 seed = SUPPLY * 9 / 10;
        assertTrue(factory.move(token, POOL_MANAGER, seed));
        assertEq(token.balanceOf(POOL_MANAGER), seed);
        assertEq(token.eligibleSupply(), SUPPLY - seed);

        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(POOL_MANAGER, 1_000e18));
        assertEq(token.balanceOf(POOL_MANAGER), seed + 1_000e18);
        assertEq(token.balanceOf(address(token)), 0, "a sell paid a fee");
    }

    function test_walletToWalletTransferIsNotTaxed() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 400e18));
        assertEq(token.balanceOf(ALICE), 600e18);
        assertEq(token.balanceOf(BOB), 400e18);
        assertEq(token.balanceOf(address(token)), 0);
        assertFalse(token.isTaxedTransfer(ALICE, BOB));
    }

    function test_transferFromRequiresAllowance() public {
        factory.move(token, ALICE, 1_000e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 1_000e18);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    // ----------------------------------------------------------------------------------------
    // Buys: 3% fee, distributed before the buyer is credited
    // ----------------------------------------------------------------------------------------

    function _launch() internal {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, POOL_MANAGER, SUPPLY * 9 / 10);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.eligibleSupply(), 0);
    }

    function _buy(address buyer, uint256 gross) internal {
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(buyer, gross));
    }

    function test_buyPaysThreePercentToTheContract() public {
        _launch();
        assertTrue(token.isTaxedTransfer(POOL_MANAGER, ALICE));
        uint256 gross = 1_000e18;
        _buy(ALICE, gross);
        assertEq(token.balanceOf(ALICE), 970e18);
        assertEq(token.balanceOf(address(token)), 30e18);
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY * 9 / 10 - gross);
        assertEq(token.totalSupply(), SUPPLY);
        // Nobody was eligible when the fee was taken: it waits for the next distribution.
        assertEq(token.pendingDistribution(), 30e18);
        assertEq(token.claimableDividendOf(ALICE), 0, "a buyer shared in its own fee");
        assertEq(token.eligibleSupply(), 970e18);
    }

    function test_buyDistributesProRataToPriorHolders() public {
        _launch();
        _buy(ALICE, 1_000e18); // 970 net, 30 pending
        _buy(BOB, 3_000e18); // 2910 net, fee 90 + 30 pending = 120 to Alice (sole eligible holder)
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 120e18, 1);
        assertEq(token.claimableDividendOf(BOB), 0, "a buyer shared in its own fee");
        assertEq(token.pendingDistribution(), 0);
        assertEq(token.totalDividendsDistributed(), 120e18);

        // Alice 970, Bob 2910 eligible (1:3). Carol buys 1000: fee 30 -> Alice 7.5, Bob 22.5.
        _buy(CAROL, 1_000e18);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 127.5e18, 1);
        assertApproxEqAbs(token.claimableDividendOf(BOB), 22.5e18, 1);
        assertEq(token.claimableDividendOf(CAROL), 0);
    }

    function test_buyerSharesOnPreBuyBalanceButNotOnNetAmount() public {
        _launch();
        _buy(ALICE, 1_000e18); // Alice 970 eligible, 30 pending
        _buy(BOB, 1_000e18); // Bob 970 eligible, 60 to Alice
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 60e18, 1);
        // Alice buys again: fee 30 split on pre-buy balances 970:970 -> 15 each.
        _buy(ALICE, 1_000e18);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 75e18, 1);
        assertApproxEqAbs(token.claimableDividendOf(BOB), 15e18, 1);
        assertEq(token.balanceOf(ALICE), 1_940e18);
    }

    function test_buyToExcludedRecipientIsNotTaxed() public {
        _launch();
        vm.prank(POOL_MANAGER);
        token.transfer(DEAD, 100e18);
        assertEq(token.balanceOf(DEAD), 100e18);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.eligibleSupply(), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Claims
    // ----------------------------------------------------------------------------------------

    function test_claimPaysOutAndStopsDoubleClaims() public {
        _launch();
        _buy(ALICE, 1_000e18);
        _buy(BOB, 3_000e18);
        uint256 contractBefore = token.balanceOf(address(token));
        vm.prank(ALICE);
        uint256 paid = token.claim();
        assertApproxEqAbs(paid, 120e18, 1);
        assertApproxEqAbs(token.balanceOf(ALICE), 970e18 + 120e18, 1);
        assertApproxEqAbs(token.balanceOf(address(token)), contractBefore - 120e18, 1);
        assertEq(token.claimableDividendOf(ALICE), 0);
        assertApproxEqAbs(token.totalDividendsClaimed(), 120e18, 1);
        assertApproxEqAbs(token.eligibleSupply(), 970e18 + 120e18 + 2_910e18, 1);
        vm.prank(ALICE);
        assertEq(token.claim(), 0);
        assertApproxEqAbs(token.balanceOf(ALICE), 970e18 + 120e18, 1);
    }

    function test_claimForPaysTheHolderNotTheCaller() public {
        _launch();
        _buy(ALICE, 1_000e18);
        _buy(BOB, 3_000e18);
        vm.prank(CAROL);
        uint256 paid = token.claimFor(ALICE);
        assertApproxEqAbs(paid, 120e18, 1);
        assertApproxEqAbs(token.balanceOf(ALICE), 1_090e18, 1);
        assertEq(token.balanceOf(CAROL), 0);
    }

    function test_claimForExcludedAccountReverts() public {
        _launch();
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, POOL_MANAGER));
        token.claimFor(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, DISTRIBUTOR));
        token.claimFor(DISTRIBUTOR);
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, address(token)));
        token.claimFor(address(token));
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, DEAD));
        token.claimFor(DEAD);
    }

    function test_transferAfterAccrualKeepsDividendsWithTheEarner() public {
        _launch();
        _buy(ALICE, 1_000e18);
        _buy(BOB, 3_000e18); // Alice owed 120
        vm.prank(ALICE);
        token.transfer(CAROL, 970e18);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 120e18, 1, "moving the balance lost accrued dividends");
        assertEq(token.claimableDividendOf(CAROL), 0, "a transfer carried dividends with it");
        // Next fee goes 2910:970 to Bob:Carol, nothing to Alice (balance 0).
        _buy(address(0xF00D), 1_000e18);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 120e18, 1);
        assertApproxEqAbs(token.claimableDividendOf(BOB), 22.5e18, 1);
        assertApproxEqAbs(token.claimableDividendOf(CAROL), 7.5e18, 1);
    }

    function test_contractBalanceCoversPendingAndUnclaimed() public {
        _launch();
        _buy(ALICE, 1_234e18);
        _buy(BOB, 5_678e18);
        _buy(CAROL, 91_011e18);
        vm.prank(BOB);
        token.claim();
        uint256 owed = token.claimableDividendOf(ALICE) + token.claimableDividendOf(BOB)
            + token.claimableDividendOf(CAROL) + token.pendingDistribution();
        uint256 held = token.balanceOf(address(token));
        assertGe(held, owed, "the contract owes more than it holds");
        assertLe(held - owed, 10, "more than rounding dust is stranded");
    }
}
