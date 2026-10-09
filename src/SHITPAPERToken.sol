// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title shitpaper (SHITPAPER)
/// @notice Fixed-supply ERC-20 with a 3% buy fee that is redistributed to holders as dividends.
/// @dev
///  - The whole supply (1,000,000,000 * 1e18) is minted once, to the deployer (the launch factory).
///    Nothing can mint afterwards; there is no owner, no admin function and no upgrade path.
///  - A buy is an ERC-20 transfer whose `from` is the Uniswap v4 PoolManager. 3% of it stays in this
///    contract and the buyer receives the rest. Transfers to the PoolManager (sells, the factory's
///    pool seed) and plain wallet-to-wallet transfers pay nothing, so v4 settlement always balances.
///  - Fees are distributed pro rata to the eligible supply at the moment of the buy, before the
///    buyer's net amount is credited, so a buyer never shares in its own fee. The PoolManager, this
///    contract, the burn address and the launch's Merkle distributor are excluded from dividends.
///  - Holders claim with claim(); anyone may call claimFor(holder) to pay a holder out.
///  - The distributor's address depends on this token's address, so it is read lazily from the
///    factory (distributorOf(launchNumber)) at transfer time and cached once it is known. The
///    constructor never calls another contract.
contract SHITPAPERToken is ERC20 {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    /// @notice 1,000,000,000 tokens with 18 decimals, minted once to the deployer.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Fee on buys (transfers out of the PoolManager), in basis points.
    uint256 public constant BUY_FEE_BPS = 300;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The burn address, excluded from dividends.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Precision of the reward-per-token accumulator.
    uint256 private constant PRECISION = 1e36;

    // ------------------------------------------------------------------------------------------
    // Launch parameters (fixed at deployment by the launch factory)
    // ------------------------------------------------------------------------------------------

    /// @notice The launch factory: the deployer and the contract that knows the distributor.
    address public immutable FACTORY;

    /// @notice The Uniswap v4 PoolManager. Transfers out of it are buys and pay the fee.
    address public immutable POOL_MANAGER;

    /// @notice The launch number this token was launched under, used to look up the distributor.
    uint64 public immutable LAUNCH_NUMBER;

    // ------------------------------------------------------------------------------------------
    // Dividend state
    // ------------------------------------------------------------------------------------------

    /// @notice The launch's Merkle distributor once it is known (zero until the factory has set it).
    address public distributor;

    /// @notice Sum of balances of every account that earns dividends.
    uint256 public eligibleSupply;

    /// @notice Cumulative dividends per eligible token, scaled by 1e36.
    uint256 public rewardPerTokenStored;

    /// @notice Fees collected while nobody was eligible, or rounding remainders: paid out with the
    /// next distribution.
    uint256 public pendingDistribution;

    /// @notice Total fees ever distributed to holders (claimed or not).
    uint256 public totalDividendsDistributed;

    /// @notice Total dividends ever paid out through claim()/claimFor().
    uint256 public totalDividendsClaimed;

    /// @dev Accumulator checkpoint of each account.
    mapping(address => uint256) private _rewardPerTokenPaid;

    /// @dev Dividends settled for each account but not yet claimed.
    mapping(address => uint256) private _owed;

    // ------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------

    /// @notice A buy paid `fee` into the contract.
    event BuyFeeCollected(address indexed buyer, uint256 grossAmount, uint256 fee);

    /// @notice `amount` of fees were distributed against `eligibleSupply`.
    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);

    /// @notice `account` was paid `amount` of dividends.
    event DividendsClaimed(address indexed account, uint256 amount);

    /// @notice The distributor address was read from the factory and cached.
    event DistributorResolved(address indexed distributor);

    /// @notice The account cannot earn or claim dividends.
    error ExcludedFromDividends(address account);

    /// @notice The launch parameters must be real addresses.
    error ZeroAddress();

    // ------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------

    /// @param factory_ The launch factory (the deployer, msg.sender) that answers distributorOf().
    /// @param poolManager_ The Uniswap v4 PoolManager the launch pool lives in.
    /// @param launchNumber_ The launch number used to look the distributor up on the factory.
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("shitpaper", "SHITPAPER") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        POOL_MANAGER = poolManager_;
        LAUNCH_NUMBER = launchNumber_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------------------------------
    // Dividends
    // ------------------------------------------------------------------------------------------

    /// @notice Pays the caller's dividends out to the caller.
    /// @return amount The amount paid.
    function claim() external returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice Pays `account`'s dividends out to `account`. Anyone may call this, so dividends
    /// credited to a contract that cannot call claim() are never locked.
    /// @return amount The amount paid.
    function claimFor(address account) external returns (uint256 amount) {
        return _claim(account);
    }

    /// @notice Dividends `account` can claim right now.
    function claimableDividendOf(address account) public view returns (uint256) {
        if (_isExcluded(account, _knownDistributor())) return 0;
        return _owed[account] + _pending(account);
    }

    /// @notice Whether `account` is excluded from dividends.
    function isExcludedFromDividends(address account) external view returns (bool) {
        return _isExcluded(account, _knownDistributor());
    }

    /// @notice Whether a transfer from `from` to `to` pays the buy fee.
    function isTaxedTransfer(address from, address to) external view returns (bool) {
        return from == POOL_MANAGER && !_isFeeExempt(to, _knownDistributor());
    }

    /// @notice The fee a buy of `amount` pays.
    function buyFeeOn(uint256 amount) public pure returns (uint256) {
        return amount * BUY_FEE_BPS / BPS_DENOMINATOR;
    }

    // ------------------------------------------------------------------------------------------
    // Transfer hook
    // ------------------------------------------------------------------------------------------

    /// @dev Every balance change goes through here: the mint, transfers, fee collection and claims.
    function _update(address from, address to, uint256 value) internal override {
        // The constructor mint: no fee, no distributor lookup (the constructor calls nobody).
        address dist = from == address(0) ? address(0) : _resolveDistributor();

        uint256 fee = 0;
        if (from == POOL_MANAGER && !_isFeeExempt(to, dist)) {
            fee = buyFeeOn(value);
        }

        // 1. Distribute the fee against the eligible supply as it stands before this transfer, so
        //    the buyer's pre-buy balance shares in it but its net amount does not.
        if (fee > 0) {
            emit BuyFeeCollected(to, value, fee);
            _distribute(fee);
        }

        // 2. Checkpoint both sides on their pre-transfer balances.
        bool fromEligible = !_isExcluded(from, dist);
        bool toEligible = !_isExcluded(to, dist);
        if (fromEligible) _settle(from);
        if (toEligible) _settle(to);

        // 3. Move the balances.
        uint256 net = value - fee;
        super._update(from, to, net);
        if (fee > 0) super._update(from, address(this), fee);

        // 4. Keep the eligible supply in step with the balances.
        if (fromEligible) eligibleSupply -= value;
        if (toEligible) eligibleSupply += net;
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _claim(address account) private returns (uint256 amount) {
        address dist = _resolveDistributor();
        if (_isExcluded(account, dist)) revert ExcludedFromDividends(account);
        _settle(account);
        amount = _owed[account];
        if (amount == 0) return 0;
        _owed[account] = 0;
        totalDividendsClaimed += amount;
        emit DividendsClaimed(account, amount);
        // Not a buy: from is this contract, so no fee, and the holder is eligible so the
        // eligible supply grows by the amount paid.
        _update(address(this), account, amount);
    }

    /// @dev Credits `amount` (plus anything pending) to every eligible token.
    function _distribute(uint256 amount) private {
        amount += pendingDistribution;
        uint256 supply = eligibleSupply;
        if (supply == 0) {
            pendingDistribution = amount;
            return;
        }
        // The whole amount is credited; what the per-holder floor division leaves behind (at most a
        // few wei) stays in the contract, so the contract always holds at least what it owes.
        pendingDistribution = 0;
        rewardPerTokenStored += amount * PRECISION / supply;
        totalDividendsDistributed += amount;
        emit DividendsDistributed(amount, supply);
    }

    /// @dev Moves `account`'s accrued dividends into `_owed` and advances its checkpoint.
    function _settle(address account) private {
        uint256 pending = _pending(account);
        if (pending > 0) _owed[account] += pending;
        _rewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    /// @dev Dividends accrued by `account` since its last checkpoint (ignores exclusion).
    function _pending(address account) private view returns (uint256) {
        uint256 delta = rewardPerTokenStored - _rewardPerTokenPaid[account];
        if (delta == 0) return 0;
        return balanceOf(account) * delta / PRECISION;
    }

    function _isExcluded(address account, address dist) private view returns (bool) {
        return account == address(0) || account == POOL_MANAGER || account == address(this) || account == BURN_ADDRESS
            || (dist != address(0) && account == dist);
    }

    /// @dev Recipients that never pay the buy fee: the launch flows and the excluded set.
    function _isFeeExempt(address to, address dist) private view returns (bool) {
        return to == FACTORY || _isExcluded(to, dist);
    }

    /// @dev The cached distributor; zero while unknown.
    function _knownDistributor() private view returns (address) {
        return distributor;
    }

    /// @dev Returns the distributor, reading it from the factory the first time it is non-zero.
    /// A factory with no code or no answer yet leaves it unknown; nothing reverts.
    function _resolveDistributor() private returns (address dist) {
        dist = distributor;
        if (dist != address(0)) return dist;
        (bool ok, bytes memory data) =
            FACTORY.staticcall(abi.encodeWithSignature("distributorOf(uint64)", LAUNCH_NUMBER));
        if (!ok || data.length != 32) return address(0);
        dist = abi.decode(data, (address));
        if (dist == address(0)) return address(0);
        distributor = dist;
        emit DistributorResolved(dist);
        // Had the distributor received tokens before the factory registered it, it would have been
        // counted as eligible; take it out of the eligible supply now. In the launch flow the
        // factory registers the distributor before it sends the swarm's share, so this is zero.
        uint256 held = balanceOf(dist);
        if (held > 0) {
            eligibleSupply -= held;
            _owed[dist] = 0;
        }
    }
}
