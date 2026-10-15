// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DEF} from "./DEF.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Charges exactly 225 bps of DEF on exact-input swaps in one native ETH/DEF pool.
/// @dev The owner can only select the sink. Claims are redeemed only to that sink.
contract ReflectionHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int128;
    using LPFeeLibrary for uint24;

    error NotPoolManager();
    error NotOwner();
    error LiquidityLocked();
    error ExactOutputUnsupported();
    error ZeroAddress();
    error SinkNotSet();
    error NothingToFlush();
    error WrongCurrency();
    error NotSink();
    error NotLaunch();
    error AlreadyInitialized();
    error WrongPool();
    error NoPendingFlush();

    /// @dev swapper is the PoolManager's immediate caller (usually a router), not tx.origin.
    event ReflectionFee(address indexed swapper, bool buy, uint256 defAmount);
    event SinkSet(address indexed sink);
    event Flushed(address indexed sink, uint256 amount);

    uint256 public constant FEE_BPS = 225;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    DEF public immutable def;
    address public immutable owner;
    address public immutable factory;

    address public sink;
    bool private flushing;
    /// @dev The static LP fee of the pool the factory opened; zero until then.
    uint24 public lpFee;
    /// @dev The id of the one pool this hook serves; zero until the factory opens it.
    bytes32 public poolId;

    /// @param manager_ The launch chain's Uniswap v4 PoolManager ($poolManager).
    /// @param def_ The DEF token deployed by the launch factory ($token).
    /// @param owner_ The launch's owner ($owner), explicitly separate from the deployer.
    /// @param factory_ The launch factory that initializes and seeds this pool ($factory).
    constructor(IPoolManager manager_, DEF def_, address owner_, address factory_) {
        if (
            address(manager_) == address(0) || address(def_) == address(0) || owner_ == address(0)
                || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = manager_;
        def = def_;
        owner = owner_;
        factory = factory_;
        // An internal, pure check; the constructor makes no calls to external contracts.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice The launch pool: native ETH against DEF, tick spacing 60, this hook, at the LP fee the
    /// factory opened it with. Before initialization the fee field reads zero and `poolId()` is zero.
    function poolKey() public view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(def)), lpFee, TICK_SPACING, IHooks(address(this)));
    }

    function initialized() public view returns (bool) {
        return poolId != bytes32(0);
    }

    function setSink(address newSink) external {
        if (msg.sender != owner) revert NotOwner();
        if (newSink == address(0)) revert ZeroAddress();
        sink = newSink;
        emit SinkSet(newSink);
    }

    function collected() public view returns (uint256) {
        return poolManager.balanceOf(address(this), _defCurrency().toId());
    }

    function claimable(address account, address currency) external view returns (uint256) {
        // Nothing is claimable by anyone until the owner names a sink.
        if (sink == address(0) || account != sink || currency != address(def)) return 0;
        return collected();
    }

    function flush() external returns (uint256 amount) {
        return _flush();
    }

    function claim(address currency, address to) external returns (uint256 amount) {
        // While no sink is set nobody is the sink, so the zero address cannot pass either check.
        if (sink == address(0) || msg.sender != sink) revert NotSink();
        if (to != sink) revert NotSink();
        if (currency != address(def)) revert WrongCurrency();
        return _flush();
    }

    function _flush() private returns (uint256 amount) {
        if (sink == address(0)) revert SinkNotSet();
        if (collected() == 0) revert NothingToFlush();
        flushing = true;
        amount = abi.decode(poolManager.unlock(""), (uint256));
    }

    /// @dev The manager only calls its unlock caller. No recipient or amount is accepted in calldata.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!flushing) revert NoPendingFlush();
        flushing = false;
        address recipient = sink;
        uint256 amount = collected();
        Currency currency = _defCurrency();
        emit Flushed(recipient, amount);
        // Burn first: cancels the take's debit and prevents a second redemption of these claims.
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        return abi.encode(amount);
    }

    /// @dev Accepts the pool the launch factory opens: ETH/DEF, spacing 60, this hook, at whichever
    /// static LP fee the factory's manifest names (the launch policy's tier, never the dynamic flag).
    /// The PoolManager bounds the fee itself. The accepted key is recorded and is the only pool served.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(def)
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this) || key.fee.isDynamicFee()
        ) {
            revert WrongPool();
        }
        if (initialized()) revert AlreadyInitialized();
        if (sender != factory && sender != address(this)) revert NotLaunch();
        lpFee = key.fee;
        poolId = PoolId.unwrap(key.toId());
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Only the launch (the factory, or the hook itself) may add liquidity; everyone else is locked out.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory && sender != address(this)) revert LiquidityLocked();
        _checkPool(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        if (params.zeroForOne) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // DEF is currency1: a sell specifies DEF input. This also handles int256.min without negation overflow.
        // params.amountSpecified is negative, so the cast's operand is in [0, int256.max].
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 specified = uint256(-(params.amountSpecified + 1)) + 1;
        uint256 fee = FullMath.mulDiv(specified, FEE_BPS, BPS_DENOMINATOR);
        int128 feeDelta = fee.toInt128();
        _mintFee(sender, false, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeDelta, 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        if (!params.zeroForOne) return (IHooks.afterSwap.selector, 0);

        // On a buy the unspecified currency is DEF. Only the actual positive output is charged.
        uint256 produced = uint256(delta.amount1().toUint128());
        uint256 fee = FullMath.mulDiv(produced, FEE_BPS, BPS_DENOMINATOR);
        int128 feeDelta = fee.toInt128();
        _mintFee(sender, true, fee);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    function _mintFee(address swapper, bool buy, uint256 fee) private {
        // PoolManager.mint only updates accounting; it cannot invoke an untrusted recipient callback.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ReflectionFee(swapper, buy, fee);
        if (fee != 0) poolManager.mint(address(this), _defCurrency().toId(), fee);
    }

    function _defCurrency() private view returns (Currency) {
        return Currency.wrap(address(def));
    }

    /// @dev Before initialization poolId is zero, which no key hashes to, so every pool is refused.
    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != poolId) revert WrongPool();
    }

    // Disabled permissions. These callbacks impose no fee or restriction on removals or donations.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
