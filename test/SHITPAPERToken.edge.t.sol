// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SHITPAPERToken} from "../src/SHITPAPERToken.sol";
import {MockFactory} from "./SHITPAPERToken.t.sol";

/// @dev A factory whose distributorOf reverts.
contract RevertingFactory {
    function deployToken(address poolManager, uint64 launchNumber) external returns (SHITPAPERToken) {
        return new SHITPAPERToken(address(this), poolManager, launchNumber);
    }

    function distributorOf(uint64) external pure returns (address) {
        revert("no distributor");
    }

    function move(SHITPAPERToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev A factory whose distributorOf returns the wrong shape.
contract MalformedFactory {
    function deployToken(address poolManager, uint64 launchNumber) external returns (SHITPAPERToken) {
        return new SHITPAPERToken(address(this), poolManager, launchNumber);
    }

    function distributorOf(uint64) external pure returns (address, address) {
        return (address(0xD157), address(0xD157));
    }

    function move(SHITPAPERToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev A holder that cannot call claim() itself (no code path for it).
contract DumbHolder {}

/// @notice Edges, failure paths and the launch-ordering corner cases.
contract SHITPAPERTokenEdgeTest is Test {
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

    function _launch() internal {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, POOL_MANAGER, SUPPLY * 9 / 10);
        factory.move(token, DEAD, token.balanceOf(address(factory)));
        assertEq(token.eligibleSupply(), 0);
    }

    function _buy(address buyer, uint256 gross) internal {
        vm.prank(POOL_MANAGER);
        token.transfer(buyer, gross);
    }

    // ----------------------------------------------------------------------------------------
    // Fixed parameters, no admin surface, no forbidden opcodes
    // ----------------------------------------------------------------------------------------

    function test_parametersAreTheBriefsConstants() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 1e18);
        assertEq(token.BUY_FEE_BPS(), 300);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.BURN_ADDRESS(), DEAD);
        assertEq(token.POOL_MANAGER(), 0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(token.decimals(), 18);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_privilegedCallsNeitherMoveNorFreezeAHolder() public {
        factory.move(token, ALICE, 1_000e18);
        string[14] memory signatures = [
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "setFee(uint256)",
            "setBuyFee(uint256)",
            "excludeFromDividends(address)",
            "setDistributor(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.BUY_FEE_BPS(), 300);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500e18));
    }

    // ----------------------------------------------------------------------------------------
    // Transfer edges
    // ----------------------------------------------------------------------------------------

    function test_selfTransferChangesNothing() public {
        _launch();
        _buy(ALICE, 1_000e18); // 970 to Alice, 30 pending
        _buy(BOB, 1_000e18); // 60 to Alice
        uint256 eligible = token.eligibleSupply();
        uint256 owed = token.claimableDividendOf(ALICE);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 970e18));
        assertEq(token.balanceOf(ALICE), 970e18);
        assertEq(token.eligibleSupply(), eligible);
        assertEq(token.claimableDividendOf(ALICE), owed);
        // The manager sending to itself is not a buy either.
        uint256 held = token.balanceOf(address(token));
        vm.prank(POOL_MANAGER);
        token.transfer(POOL_MANAGER, 1_000e18);
        assertEq(token.balanceOf(address(token)), held);
        assertEq(token.eligibleSupply(), eligible);
    }

    function test_zeroAmountTransfersSucceedAndChargeNothing() public {
        _launch();
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(ALICE, 0));
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.pendingDistribution(), 0);
        assertEq(token.eligibleSupply(), 0);
    }

    function test_buyToFeeExemptRecipientsIsNotTaxed() public {
        _launch();
        address[4] memory exempt = [address(factory), address(token), DISTRIBUTOR, DEAD];
        for (uint256 i; i < exempt.length; ++i) {
            assertFalse(token.isTaxedTransfer(POOL_MANAGER, exempt[i]));
            uint256 before = token.balanceOf(exempt[i]);
            _buy(exempt[i], 100e18);
            assertEq(token.balanceOf(exempt[i]), before + 100e18, "an exempt recipient was taxed");
        }
        // Only the factory among them is eligible for dividends.
        assertEq(token.eligibleSupply(), 100e18);
        assertEq(token.balanceOf(address(token)), 100e18, "the direct send to the contract is not a fee");
        assertEq(token.pendingDistribution(), 0, "a direct send to the contract became dividends");
    }

    function test_tokensSentToTheContractAreNotRedistributed() public {
        _launch();
        _buy(ALICE, 1_000e18); // 30 pending
        vm.prank(ALICE);
        token.transfer(address(token), 100e18);
        assertEq(token.pendingDistribution(), 30e18);
        assertEq(token.eligibleSupply(), 870e18);
        _buy(BOB, 1_000e18); // 30 + 30 to Alice
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 60e18, 1, "a donation was redistributed");
        assertEq(token.balanceOf(address(token)), 160e18);
    }

    function test_burnAddressAccumulatesWithoutEarning() public {
        _launch();
        _buy(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.transfer(DEAD, 470e18);
        assertEq(token.eligibleSupply(), 500e18);
        _buy(BOB, 1_000e18);
        assertEq(token.claimableDividendOf(DEAD), 0);
        assertApproxEqAbs(token.claimableDividendOf(ALICE), 60e18, 1);
        assertEq(token.totalSupply(), SUPPLY, "a burn changed the supply");
    }

    // ----------------------------------------------------------------------------------------
    // Dividend edges
    // ----------------------------------------------------------------------------------------

    function test_claimForZeroAddressReverts() public {
        _launch();
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, address(0)));
        token.claimFor(address(0));
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_claimWithNothingOwedPaysZeroAndEmitsNothing() public {
        _launch();
        vm.recordLogs();
        vm.prank(ALICE);
        assertEq(token.claim(), 0);
        assertEq(vm.getRecordedLogs().length, 0, "an empty claim emitted something");
    }

    function test_contractHolderIsPaidThroughClaimFor() public {
        _launch();
        DumbHolder holder = new DumbHolder();
        _buy(address(holder), 1_000e18);
        _buy(BOB, 1_000e18); // 60 to the holder
        assertApproxEqAbs(token.claimableDividendOf(address(holder)), 60e18, 1);
        vm.prank(CAROL);
        uint256 paid = token.claimFor(address(holder));
        assertApproxEqAbs(paid, 60e18, 1);
        assertApproxEqAbs(token.balanceOf(address(holder)), 1_030e18, 1);
    }

    function test_claimEmitsEventsAndTransferFromTheContract() public {
        _launch();
        _buy(ALICE, 1_000e18);
        _buy(BOB, 1_000e18);
        uint256 owed = token.claimableDividendOf(ALICE);
        vm.expectEmit(true, true, true, true, address(token));
        emit SHITPAPERToken.DividendsClaimed(ALICE, owed);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(address(token), ALICE, owed);
        vm.prank(ALICE);
        token.claim();
    }

    function test_buyEmitsFeeTransferAndDistributionEvents() public {
        _launch();
        _buy(ALICE, 1_000e18);
        // Bob's buy: 30 fee + 30 pending distributed against Alice's 970.
        vm.expectEmit(true, true, true, true, address(token));
        emit SHITPAPERToken.BuyFeeCollected(BOB, 1_000e18, 30e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit SHITPAPERToken.DividendsDistributed(60e18, 970e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(POOL_MANAGER, BOB, 970e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(POOL_MANAGER, address(token), 30e18);
        _buy(BOB, 1_000e18);
    }

    function test_manyTinyDistributionsNeverMakeTheContractInsolvent() public {
        _launch();
        _buy(ALICE, 7_777e18 + 13);
        _buy(BOB, 1_234e18 + 7);
        _buy(CAROL, 999e18 + 1);
        for (uint256 i; i < 50; ++i) {
            _buy(address(uint160(0xF00D + i)), 34 + i * 7);
        }
        uint256 owed = token.pendingDistribution() + token.claimableDividendOf(ALICE) + token.claimableDividendOf(BOB)
            + token.claimableDividendOf(CAROL);
        for (uint256 i; i < 50; ++i) {
            owed += token.claimableDividendOf(address(uint160(0xF00D + i)));
        }
        uint256 held = token.balanceOf(address(token));
        assertGe(held, owed, "insolvent");
        assertLe(held - owed, 53 * 53, "more than dust stranded");
        // Everyone can actually be paid, in any order.
        for (uint256 i; i < 50; ++i) {
            token.claimFor(address(uint160(0xF00D + i)));
        }
        token.claimFor(CAROL);
        token.claimFor(ALICE);
        token.claimFor(BOB);
        assertEq(token.totalDividendsClaimed(), token.totalDividendsDistributed() - (token.balanceOf(address(token))));
    }

    function test_hugeFeeAgainstOneWeiOfEligibleSupplyDoesNotOverflowLater() public {
        _launch();
        // Alice holds 1 wei; a near-whole-pool buy is distributed against it.
        _buy(ALICE, 1);
        assertEq(token.eligibleSupply(), 1);
        uint256 pool = token.balanceOf(POOL_MANAGER);
        _buy(BOB, pool); // fee 3% of ~9e26
        uint256 fee = pool * 300 / 10_000;
        assertEq(token.claimableDividendOf(ALICE), fee, "the sole wei did not earn the whole fee");
        // Later arithmetic on the large holder must still work.
        vm.prank(BOB);
        token.transfer(CAROL, 1e18);
        token.claimFor(ALICE);
        token.claimFor(BOB);
        assertEq(token.claimableDividendOf(BOB), 0);
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 1);
        vm.prank(BOB);
        token.transfer(POOL_MANAGER, 10_000e18); // a sell refills the pool
        _buy(CAROL, 1_000e18);
        assertGt(token.claimableDividendOf(BOB), 0);
        assertGt(token.claimableDividendOf(CAROL), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Distributor resolution: ordering and factories that do not answer
    // ----------------------------------------------------------------------------------------

    function test_unresolvedDistributorIsTaxedAndEligibleUntilTheFactoryRegistersIt() public view {
        assertEq(token.distributor(), address(0));
        assertFalse(token.isExcludedFromDividends(DISTRIBUTOR));
        assertTrue(token.isTaxedTransfer(POOL_MANAGER, DISTRIBUTOR));
    }

    function test_distributorFundedBeforeRegistrationIsRemovedFromEligibleSupplyOnResolution() public {
        // Out-of-order launch: tokens reach the distributor before the factory registers it.
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, POOL_MANAGER, SUPPLY * 9 / 10);
        assertEq(token.eligibleSupply(), SUPPLY / 10, "unregistered distributor counted as a holder");
        _buy(ALICE, 1_000e18); // 30 distributed to the distributor (the only eligible holder)
        assertApproxEqAbs(token.claimableDividendOf(DISTRIBUTOR), 30e18, 1);

        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        vm.expectEmit(true, true, true, true, address(token));
        emit SHITPAPERToken.DistributorResolved(DISTRIBUTOR);
        vm.prank(ALICE);
        token.transfer(BOB, 1);

        assertEq(token.distributor(), DISTRIBUTOR);
        assertEq(token.eligibleSupply(), 970e18, "distributor still counted");
        assertEq(token.claimableDividendOf(DISTRIBUTOR), 0);
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, DISTRIBUTOR));
        token.claimFor(DISTRIBUTOR);
        // Its forfeited 30 stays in the contract; nobody else is credited for it, and the contract
        // still covers what it owes.
        assertGe(token.balanceOf(address(token)), token.claimableDividendOf(ALICE) + token.claimableDividendOf(BOB));
        // The swarm's share is still whole and still claimable whole.
        vm.prank(DISTRIBUTOR);
        token.transfer(CAROL, SUPPLY / 10);
        assertEq(token.balanceOf(CAROL), SUPPLY / 10);
        assertEq(token.eligibleSupply(), 970e18 + SUPPLY / 10);
    }

    function test_distributorResolvedWhileItIsTheSenderDoesNotDoubleCount() public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        // First transfer after registration is the distributor paying a claim.
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 1_000e18);
        assertEq(token.eligibleSupply(), SUPPLY - SUPPLY / 10 + 1_000e18);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10 - 1_000e18);
    }

    function test_distributorResolvedWhileItIsTheRecipientDoesNotDoubleCount() public {
        factory.move(token, DISTRIBUTOR, 1_000e18);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, 1_000e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 2_000e18);
        assertEq(token.eligibleSupply(), SUPPLY - 2_000e18);
    }

    function test_deployerWithoutCodeLeavesTheDistributorUnknownAndTransfersWork() public {
        address eoa = address(0xE0A);
        vm.prank(eoa);
        SHITPAPERToken t = new SHITPAPERToken(eoa, POOL_MANAGER, LAUNCH);
        assertEq(t.balanceOf(eoa), SUPPLY);
        vm.prank(eoa);
        assertTrue(t.transfer(ALICE, 1_000e18));
        assertEq(t.distributor(), address(0));
        vm.prank(ALICE);
        assertEq(t.claim(), 0);
    }

    function test_revertingFactoryLookupDoesNotBlockTransfers() public {
        RevertingFactory rf = new RevertingFactory();
        SHITPAPERToken t = rf.deployToken(POOL_MANAGER, LAUNCH);
        assertTrue(rf.move(t, ALICE, 1_000e18));
        assertEq(t.distributor(), address(0));
        rf.move(t, POOL_MANAGER, t.balanceOf(address(rf)));
        vm.prank(POOL_MANAGER);
        t.transfer(BOB, 1_000e18);
        assertEq(t.balanceOf(BOB), 970e18);
        assertApproxEqAbs(t.claimableDividendOf(ALICE), 30e18, 1);
    }

    function test_malformedFactoryAnswerIsIgnored() public {
        MalformedFactory mf = new MalformedFactory();
        SHITPAPERToken t = mf.deployToken(POOL_MANAGER, LAUNCH);
        assertTrue(mf.move(t, ALICE, 1_000e18));
        assertEq(t.distributor(), address(0), "a 64-byte answer was decoded as an address");
    }

    function test_distributorIsCachedOnceAndNotReReadIfTheFactoryChangesIt() public {
        _launch();
        factory.setDistributor(LAUNCH, BOB);
        _buy(ALICE, 1_000e18);
        assertEq(token.distributor(), DISTRIBUTOR, "the cached distributor was replaced");
        assertFalse(token.isExcludedFromDividends(BOB));
    }

    function test_differentLaunchNumberReadsItsOwnDistributor() public {
        SHITPAPERToken other = factory.deployToken(POOL_MANAGER, 948);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(other, ALICE, 1);
        assertEq(other.distributor(), address(0), "read another launch's distributor");
        factory.setDistributor(948, CAROL);
        factory.move(other, ALICE, 1);
        assertEq(other.distributor(), CAROL);
    }

    // ----------------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------------

    function test_viewsAgreeWithState() public {
        _launch();
        assertTrue(token.isTaxedTransfer(POOL_MANAGER, ALICE));
        assertFalse(token.isTaxedTransfer(ALICE, POOL_MANAGER));
        assertFalse(token.isTaxedTransfer(POOL_MANAGER, POOL_MANAGER));
        assertFalse(token.isTaxedTransfer(POOL_MANAGER, address(factory)));
        assertEq(token.buyFeeOn(0), 0);
        assertEq(token.buyFeeOn(10_000), 300);
        assertEq(token.buyFeeOn(SUPPLY), SUPPLY * 3 / 100);
        assertFalse(token.isExcludedFromDividends(ALICE));
        assertTrue(token.isExcludedFromDividends(address(0)));
    }
}
