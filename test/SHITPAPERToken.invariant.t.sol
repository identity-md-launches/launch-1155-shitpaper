// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SHITPAPERToken} from "../src/SHITPAPERToken.sol";
import {MockFactory} from "./SHITPAPERToken.t.sol";

/// @dev Drives the token through random buys, sells, transfers, burns, donations, distributor
/// claims and dividend claims with bounded inputs, and keeps ghost totals to compare against.
contract Handler is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);

    SHITPAPERToken public immutable token;
    MockFactory public immutable factory;
    address[] public actors;

    uint256 public ghostFees; // every buy fee ever charged
    uint256 public ghostDonated; // tokens sent straight to the contract, never owed to anyone
    uint256 public ghostDistributions; // number of distributions against a non-zero eligible supply
    uint256 public ghostClaimed; // what claim()/claimFor() actually delivered
    mapping(address => uint256) public ghostClaimedBy;
    uint256 public calls;

    constructor(SHITPAPERToken token_, MockFactory factory_) {
        token = token_;
        factory = factory_;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA7E));
        actors.push(address(0xE7E));
        actors.push(address(factory_)); // eligible like any wallet, and the fee-exempt buyer
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _distributionWillHappen(uint256 fee) internal view returns (bool) {
        return (fee + token.pendingDistribution()) > 0 && token.eligibleSupply() > 0;
    }

    /// @dev A buy: the manager sends `gross` to an actor; 3% stays in the contract unless the
    /// recipient is the factory (fee-exempt).
    function buy(uint256 who, uint256 gross) external {
        address to = _actor(who);
        gross = bound(gross, 0, token.balanceOf(POOL_MANAGER));
        uint256 fee = to == address(factory) ? 0 : token.buyFeeOn(gross);
        if (_distributionWillHappen(fee)) ghostDistributions++;
        vm.prank(POOL_MANAGER);
        token.transfer(to, gross);
        ghostFees += fee;
        calls++;
    }

    /// @dev A sell: an actor sends to the manager, never taxed.
    function sell(uint256 who, uint256 amount) external {
        address from = _actor(who);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(POOL_MANAGER, amount);
        calls++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
        calls++;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        calls++;
    }

    function burn(uint256 who, uint256 amount) external {
        address from = _actor(who);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(DEAD, amount);
        calls++;
    }

    /// @dev A mistaken donation straight to the token contract: never redistributed.
    function donate(uint256 who, uint256 amount) external {
        address from = _actor(who);
        amount = bound(amount, 0, token.balanceOf(from) / 1000);
        vm.prank(from);
        token.transfer(address(token), amount);
        ghostDonated += amount;
        calls++;
    }

    /// @dev A contributor claims part of the swarm's share from the distributor.
    function distributorClaim(uint256 who, uint256 amount) external {
        address to = _actor(who);
        amount = bound(amount, 0, token.balanceOf(DISTRIBUTOR));
        vm.prank(DISTRIBUTOR);
        token.transfer(to, amount);
        calls++;
    }

    function claim(uint256 who) external {
        address who_ = _actor(who);
        uint256 expected = token.claimableDividendOf(who_);
        vm.prank(who_);
        uint256 paid = token.claim();
        require(paid == expected, "claim paid something other than claimable");
        ghostClaimed += paid;
        ghostClaimedBy[who_] += paid;
        calls++;
    }

    function claimFor(uint256 who, uint256 callerSeed) external {
        address who_ = _actor(who);
        address caller = _actor(callerSeed);
        uint256 expected = token.claimableDividendOf(who_);
        uint256 callerBefore = token.balanceOf(caller);
        vm.prank(caller);
        uint256 paid = token.claimFor(who_);
        require(paid == expected, "claimFor paid something other than claimable");
        if (caller != who_) require(token.balanceOf(caller) == callerBefore, "claimFor paid the caller");
        ghostClaimed += paid;
        ghostClaimedBy[who_] += paid;
        calls++;
    }

    /// @dev Excluded accounts can never be paid, by anyone.
    function claimForExcluded(uint256 which) external {
        address[4] memory excluded = [POOL_MANAGER, DISTRIBUTOR, DEAD, address(token)];
        address target = excluded[which % 4];
        vm.expectRevert(abi.encodeWithSelector(SHITPAPERToken.ExcludedFromDividends.selector, target));
        token.claimFor(target);
        calls++;
    }
}

/// @notice Properties that must hold after any sequence of calls.
contract SHITPAPERTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 947;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);

    MockFactory factory;
    SHITPAPERToken token;
    Handler handler;

    function setUp() public {
        factory = new MockFactory();
        token = factory.deployToken(POOL_MANAGER, LAUNCH);
        // The launch flow as the factory performs it.
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, POOL_MANAGER, SUPPLY * 9 / 10);
        factory.move(token, DEAD, token.balanceOf(address(factory)));
        assertEq(token.eligibleSupply(), 0);

        handler = new Handler(token, factory);
        targetContract(address(handler));
    }

    function _sumActorBalances() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
    }

    function _sumClaimable() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.claimableDividendOf(handler.actors(i));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        uint256 all = _sumActorBalances() + token.balanceOf(POOL_MANAGER) + token.balanceOf(DISTRIBUTOR)
            + token.balanceOf(DEAD) + token.balanceOf(address(token));
        assertEq(all, SUPPLY, "balances do not add up to the supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_eligibleSupplyIsTheSumOfEligibleBalances() public view {
        assertEq(token.eligibleSupply(), _sumActorBalances(), "eligible supply drifted from eligible balances");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_contractHoldsWhatItOwesAndNotMuchMore() public view {
        uint256 owed = _sumClaimable() + token.pendingDistribution();
        uint256 held = token.balanceOf(address(token));
        assertGe(held, owed, "the contract owes more than it holds");
        // Only donations and floor-division dust (less than one wei per holder per distribution) may
        // sit in the contract unowed.
        uint256 dustBound = handler.ghostDistributions() * (handler.actorCount() + 1);
        assertLe(held - owed, handler.ghostDonated() + dustBound, "more than dust is stranded");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_feesAreAccountedFor() public view {
        assertEq(
            token.totalDividendsDistributed() + token.pendingDistribution(),
            handler.ghostFees(),
            "fees collected != distributed + pending"
        );
        assertEq(token.totalDividendsClaimed(), handler.ghostClaimed(), "claimed counter disagrees with payouts");
        assertLe(token.totalDividendsClaimed(), token.totalDividendsDistributed(), "more claimed than distributed");
        assertLe(
            token.totalDividendsClaimed() + _sumClaimable(),
            token.totalDividendsDistributed(),
            "claimed plus claimable exceeds distributed"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 40
    function invariant_excludedAccountsNeverEarn() public view {
        assertEq(token.claimableDividendOf(POOL_MANAGER), 0);
        assertEq(token.claimableDividendOf(DISTRIBUTOR), 0);
        assertEq(token.claimableDividendOf(DEAD), 0);
        assertEq(token.claimableDividendOf(address(token)), 0);
        assertEq(token.distributor(), DISTRIBUTOR);
    }
}
