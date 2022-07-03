// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IMUSD.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./interfaces/external/univ3/IUniswapV3Factory.sol";
import "./interfaces/external/univ3/IUniswapV3Pool.sol";
import "./interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./interfaces/oracles/IOracle.sol";
import "./libraries/external/LiquidityAmounts.sol";
import "./libraries/external/FullMath.sol";
import "./libraries/external/TickMath.sol";
import "./utils/DefaultAccessControl.sol";

contract Vault is DefaultAccessControl {
    /// @notice Thrown when a value is not valid.
    error AllowList();

    error CollateralTokenOverflow(address token);
    error CollateralUnderflow();
    error DebtOverflow();

    /// @notice Thrown when a pool address is not valid.
    error InvalidPool();

    /// @notice Thrown when a value is not valid.
    error InvalidValue();

    /// @notice Thrown when system is paused.
    error Paused();

    /// @notice Thrown when position is healthy.
    error PositionHealthy();

    /// @notice Thrown when position is unhealthy.
    error PositionUnhealthy();

    /// @notice Thrown when token capital limit has been set.
    error TokenSet();

    /// @notice Thrown when debt has not been paid.
    error UnpaidDebt();

    /// @notice Thrown when debt limit has been exceeded.
    error DebtLimitExceeded();

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant YEAR = 365 * 24 * 3600;
    uint256 public constant Q128 = 2**128;
    uint256 public constant Q96 = 2**96;

    /// @notice Collateral position information.
    /// @param token0 First token in UniswapV3 position
    /// @param token1 Second token in UniswapV3 position
    /// @param fee Fee of Uniswap position
    /// @param positionKey Key of a specific position in UniswapV3 pool
    /// @param liquidity Overall liquidity in UniswapV3 position
    /// @param feeGrowthInside0LastX128 Fee growth of token0 inside the tick range as of the last mint/burn in UniswapV3 position
    /// @param feeGrowthInside1LastX128 Fee growth of token1 inside the tick range as of the last mint/burn in UniswapV3 position
    /// @param tokensOwed0 The computed amount of token0 owed to the position as of the last mint/burn
    /// @param tokensOwed1 The computed amount of token1 owed to the position as of the last mint/burn
    /// @param sqrtRatioAX96 UniswapV3 sqrtPriceA * 2**96
    /// @param sqrtRatioBX96 UniswapV3 sqrtPriceB * 2**96
    /// @param targetPool Address of UniswapV3 pool, which contains collateral position
    /// @param vaultId Id of Mellow Vault, which takes control over collateral nft
    struct PositionInfo {
        address token0;
        address token1;
        uint24 fee;
        bytes32 positionKey;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint160 sqrtRatioAX96;
        uint160 sqrtRatioBX96;
        IUniswapV3Pool targetPool;
        uint256 vaultId;
    }

    /// @notice UniswapV3 position manager (remains constant after contract creation).
    INonfungiblePositionManager public immutable positionManager;

    /// @notice UniswapV3 factory (remains constant after contract creation).
    IUniswapV3Factory public immutable factory;

    /// @notice Protocol governance, which controls this specific Vault (remains constant after contract creation).
    IProtocolGovernance public immutable protocolGovernance;

    /// @notice Oracle for price estimation.
    IOracle public oracle;

    /// @notice Mellow Stable Token.
    IMUSD public token;

    /// @notice Vault fees treasury address (remains constant after contract creation).
    address public immutable treasury;

    /// @notice State variable, which shows if Vault is paused or not.
    bool public isPaused = false;

    /// @notice State variable, which shows if Vault is private or not.
    bool public isPrivate = true;

    EnumerableSet.AddressSet private _depositorsAllowlist;
    mapping(address => EnumerableSet.UintSet) private _ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;

    /// @notice Mapping, returning vault owner by vault id.
    mapping(uint256 => address) public vaultOwner;

    /// @notice Mapping, returning debt by vault id.
    mapping(uint256 => uint256) public debt;

    /// @notice Mapping, returning debt fee by vault id.
    mapping(uint256 => uint256) public debtFee;

    mapping(uint256 => uint256) private _lastDebtFeeUpdateTimestamp;

    /// @notice Mapping, returning max collateral supply by token address.
    mapping(address => uint256) public maxCollateralSupply;

    mapping(uint256 => PositionInfo) private _positionInfo;

    /// @notice State variable, returning vaults quantity (gets incremented after opening a new vault).
    uint256 public vaultCount = 0;

    /// @notice Array, contatining stabilisation fee updates history.
    uint256[] public stabilisationFeeUpdate;

    /// @notice Array, contatining stabilisation fee update timestamps history.
    uint256[] public stabilisationFeeUpdateTimestamp;

    constructor(
        address admin,
        INonfungiblePositionManager positionManager_,
        IUniswapV3Factory factory_,
        IProtocolGovernance protocolGovernance_,
        IOracle oracle_,
        address treasury_,
        uint256 stabilisationFee_
    ) DefaultAccessControl(admin) {
        if (
            address(positionManager_) == address(0) ||
            address(factory_) == address(0) ||
            address(protocolGovernance_) == address(0) ||
            address(oracle_) == address(0) ||
            address(treasury_) == address(0)
        ) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        factory = factory_;
        protocolGovernance = protocolGovernance_;
        oracle = oracle_;
        treasury = treasury_;

        // initial value

        stabilisationFeeUpdate.push(stabilisationFee_);
        stabilisationFeeUpdateTimestamp.push(block.timestamp);
    }

    // -------------------   PUBLIC, VIEW   -------------------

    function calculateHealthFactor(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            uint256 nft = _vaultNfts[vaultId].at(i);
            uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(
                address(_positionInfo[nft].targetPool)
            );
            result += _calculatePosition(_positionInfo[nft], liquidationThreshold);
        }
        return result;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    function ownedVaultsByAddress(address target) external view returns (uint256[] memory) {
        return _ownedVaults[target].values();
    }

    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory) {
        return _vaultNfts[vaultId].values();
    }

    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    function getOverallDebt(uint256 vaultId) external view returns (uint256) {
        return debt[vaultId] + debtFee[vaultId] + _calculateDebtFees(vaultId);
    }

    function stabilisationFee() external view returns (uint256) {
        return stabilisationFeeUpdate[stabilisationFeeUpdate.length - 1];
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    function openVault() external returns (uint256 vaultId) {
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        ++vaultCount;
        _ownedVaults[msg.sender].add(vaultCount);
        vaultOwner[vaultCount] = msg.sender;
        _lastDebtFeeUpdateTimestamp[vaultCount] = block.timestamp;

        emit VaultOpened(tx.origin, msg.sender, vaultCount);

        return vaultCount;
    }

    function closeVault(uint256 vaultId) external {
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        if (debt[vaultId] != 0 || debtFee[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, msg.sender, msg.sender);

        emit VaultClosed(tx.origin, msg.sender, vaultId);
    }

    function depositCollateral(uint256 vaultId, uint256 nft) external {
        _checkIsPaused();
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        {
            (
                ,
                ,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            ) = positionManager.positions(nft);
            IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

            if (!protocolGovernance.isPoolWhitelisted(address(pool))) {
                revert InvalidPool();
            }

            positionManager.transferFrom(msg.sender, address(this), nft);

            _positionInfo[nft] = PositionInfo({
                token0: token0,
                token1: token1,
                fee: fee,
                positionKey: keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper)),
                liquidity: liquidity,
                feeGrowthInside0LastX128: feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: feeGrowthInside1LastX128,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1,
                sqrtRatioAX96: TickMath.getSqrtRatioAtTick(tickLower),
                sqrtRatioBX96: TickMath.getSqrtRatioAtTick(tickUpper),
                targetPool: pool,
                vaultId: vaultId
            });
        }

        PositionInfo memory position = _positionInfo[nft];

        uint256 token0LimitImpact = LiquidityAmounts.getAmount0ForLiquidity(
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );
        uint256 token1LimitImpact = LiquidityAmounts.getAmount1ForLiquidity(
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );

        if (_calculatePosition(position, DENOMINATOR) < protocolGovernance.protocolParams().minSingleNftCapital) {
            revert CollateralUnderflow();
        }

        maxCollateralSupply[position.token0] += token0LimitImpact;

        if (maxCollateralSupply[position.token0] > protocolGovernance.getTokenLimit(position.token0)) {
            revert CollateralTokenOverflow(position.token0);
        }

        maxCollateralSupply[position.token1] += token1LimitImpact;

        if (maxCollateralSupply[position.token1] > protocolGovernance.getTokenLimit(position.token1)) {
            revert CollateralTokenOverflow(position.token1);
        }

        _vaultNfts[vaultId].add(nft);

        emit CollateralDeposited(tx.origin, msg.sender, vaultId, nft);
    }

    function withdrawCollateral(uint256 nft) external {
        _checkIsPaused();
        PositionInfo memory position = _positionInfo[nft];
        _requireVaultOwner(position.vaultId);
        _updateDebtFees(position.vaultId);

        uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(address(position.targetPool));
        uint256 result = calculateHealthFactor(position.vaultId) - _calculatePosition(position, liquidationThreshold);

        // checking that health factor is more or equal than 1
        if (result < debt[position.vaultId] + debtFee[position.vaultId]) {
            revert PositionUnhealthy();
        }

        positionManager.transferFrom(address(this), msg.sender, nft);

        uint256 token0LimitImpact = LiquidityAmounts.getAmount0ForLiquidity(
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );
        uint256 token1LimitImpact = LiquidityAmounts.getAmount1ForLiquidity(
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );

        maxCollateralSupply[position.token0] -= token0LimitImpact;
        maxCollateralSupply[position.token1] -= token1LimitImpact;

        _vaultNfts[position.vaultId].remove(nft);
        delete _positionInfo[nft];

        emit CollateralWithdrew(tx.origin, msg.sender, position.vaultId, nft);
    }

    function mintDebt(uint256 vaultId, uint256 amount) external {
        _checkIsPaused();
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        uint256 healthFactor = calculateHealthFactor(vaultId);

        if (healthFactor < debt[vaultId] + debtFee[vaultId] + amount) {
            revert PositionUnhealthy();
        }

        uint256 debtLimit = protocolGovernance.protocolParams().maxDebtPerVault;
        if (debtLimit < debt[vaultId] + debtFee[vaultId] + amount) {
            revert DebtLimitExceeded();
        }

        token.mint(msg.sender, amount);
        debt[vaultId] += amount;

        emit DebtMinted(tx.origin, msg.sender, vaultId, amount);
    }

    function burnDebt(uint256 vaultId, uint256 amount) external {
        _checkIsPaused();
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        amount = (amount < (debtFee[vaultId] + debt[vaultId])) ? amount : (debtFee[vaultId] + debt[vaultId]);

        if (amount > debt[vaultId]) {
            uint256 burningFeeAmount = amount - debt[vaultId];
            token.mint(treasury, burningFeeAmount);
            debtFee[vaultId] -= burningFeeAmount;
            amount -= burningFeeAmount;
            token.burn(msg.sender, burningFeeAmount);
        }

        token.burn(msg.sender, amount);
        debt[vaultId] -= amount;

        emit DebtBurned(tx.origin, msg.sender, vaultId, amount);
    }

    function liquidate(uint256 vaultId) external {
        _updateDebtFees(vaultId);

        uint256 healthFactor = calculateHealthFactor(vaultId);
        uint256 overallDebt = debt[vaultId] + debtFee[vaultId];
        if (healthFactor >= overallDebt) {
            revert PositionHealthy();
        }

        address owner = vaultOwner[vaultId];

        uint256 vaultAmount = _calculateVaultAmount(vaultId);
        uint256 returnAmount = FullMath.mulDiv(
            DENOMINATOR - protocolGovernance.protocolParams().liquidationPremium,
            vaultAmount,
            DENOMINATOR
        );
        token.transferFrom(msg.sender, address(this), returnAmount);

        uint256 daoReceiveAmount = debtFee[vaultId] +
            FullMath.mulDiv(protocolGovernance.protocolParams().liquidationFee, vaultAmount, DENOMINATOR);
        token.transfer(treasury, daoReceiveAmount);
        token.transfer(owner, returnAmount - daoReceiveAmount - overallDebt);
        token.burn(owner, debt[vaultId]);

        _closeVault(vaultId, owner, msg.sender);

        emit VaultLiquidated(tx.origin, msg.sender, vaultId);
    }

    function setOracle(IOracle oracle_) external {
        _requireAdmin();
        if (address(oracle_) == address(0)) {
            revert AddressZero();
        }
        oracle = oracle_;

        emit OracleUpdated(tx.origin, msg.sender, address(oracle));
    }

    function setToken(IMUSD token_) external {
        _requireAdmin();
        if (address(token_) == address(0)) {
            revert AddressZero();
        }
        if (address(token) != address(0)) {
            revert TokenSet();
        }
        token = token_;

        emit TokenUpdated(tx.origin, msg.sender, address(token));
    }

    function pause() external {
        _requireAtLeastOperator();
        isPaused = true;

        emit SystemPaused(tx.origin, msg.sender);
    }

    function unpause() external {
        _requireAdmin();
        isPaused = false;

        emit SystemUnpaused(tx.origin, msg.sender);
    }

    function makePrivate() external {
        _requireAdmin();
        isPrivate = true;

        emit SystemPrivate(tx.origin, msg.sender);
    }

    function makePublic() external {
        _requireAdmin();
        isPrivate = false;

        emit SystemPublic(tx.origin, msg.sender);
    }

    function addDepositorsToAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.add(depositors[i]);
        }
    }

    function removeDepositorsFromAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.remove(depositors[i]);
        }
    }

    function updateStabilisationFee(uint256 stabilisationFee_) external {
        _requireAdmin();
        if (stabilisationFee_ > DENOMINATOR) {
            revert InvalidValue();
        }
        if (block.timestamp > stabilisationFeeUpdateTimestamp[stabilisationFeeUpdateTimestamp.length - 1]) {
            stabilisationFeeUpdate.push(stabilisationFee_);
            stabilisationFeeUpdateTimestamp.push(block.timestamp);
        } else {
            stabilisationFeeUpdate[stabilisationFeeUpdate.length - 1] = stabilisationFee_;
        }

        emit StabilisationFeeUpdated(tx.origin, msg.sender, stabilisationFee_);
    }

    // -------------------  INTERNAL, VIEW  -----------------------

    function _calculateVaultAmount(uint256 vaultId) internal view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            uint256 nft = _vaultNfts[vaultId].at(i);
            result += _calculatePosition(_positionInfo[nft], DENOMINATOR);
        }
        return result;
    }

    function _calculatePosition(PositionInfo memory position, uint256 liquidationThreshold)
        internal
        view
        returns (uint256)
    {
        uint256[] memory tokenAmounts = new uint256[](2);
        (uint160 sqrtRatioX96, , , , , , ) = position.targetPool.slot0();

        (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );

        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = position.targetPool.positions(
            position.positionKey
        );

        tokenAmounts[0] +=
            position.tokensOwed0 +
            uint128(
                FullMath.mulDiv(feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128, position.liquidity, Q128)
            );

        tokenAmounts[1] +=
            position.tokensOwed1 +
            uint128(
                FullMath.mulDiv(feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128, position.liquidity, Q128)
            );

        uint256[] memory pricesX96 = new uint256[](2);
        pricesX96[0] = oracle.price(position.token0);
        pricesX96[1] = oracle.price(position.token1);

        uint256 result = 0;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 tokenAmountsUSD = FullMath.mulDiv(tokenAmounts[i], pricesX96[i], Q96);
            result += FullMath.mulDiv(tokenAmountsUSD, liquidationThreshold, DENOMINATOR);
        }

        return result;
    }

    function _requireVaultOwner(uint256 vaultId) internal view {
        if (vaultOwner[vaultId] != msg.sender) {
            revert Forbidden();
        }
    }

    function _checkIsPaused() internal view {
        if (isPaused) {
            revert Paused();
        }
    }

    function _calculateDebtFees(uint256 vaultId) internal view returns (uint256 debtDelta) {
        debtDelta = 0;
        uint256 lastDebtFeeUpdateTimestamp = _lastDebtFeeUpdateTimestamp[vaultId];
        uint256 timeElapsed = block.timestamp - lastDebtFeeUpdateTimestamp;
        if (debt[vaultId] == 0 || timeElapsed == 0) {
            return debtDelta;
        }
        uint256 timeUpperBound = block.timestamp;
        for (uint256 i = stabilisationFeeUpdate.length; i > 0; --i) {
            // avoiding overflow
            uint256 timeLowerBound = stabilisationFeeUpdateTimestamp[i - 1] > lastDebtFeeUpdateTimestamp
                ? stabilisationFeeUpdateTimestamp[i - 1]
                : lastDebtFeeUpdateTimestamp;

            if (timeLowerBound >= timeUpperBound) {
                break;
            }

            uint256 factor = FullMath.mulDiv(timeUpperBound - timeLowerBound, stabilisationFeeUpdate[i - 1], YEAR);
            debtDelta += FullMath.mulDiv(debt[vaultId], factor, DENOMINATOR);

            timeUpperBound = stabilisationFeeUpdateTimestamp[i - 1];
        }
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    function _closeVault(
        uint256 vaultId,
        address owner,
        address nftsRecipient
    ) internal {
        uint256[] memory nfts = _vaultNfts[vaultId].values();

        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            PositionInfo memory position = _positionInfo[nfts[i]];

            uint256 token0LimitImpact = LiquidityAmounts.getAmount0ForLiquidity(
                position.sqrtRatioAX96,
                position.sqrtRatioBX96,
                position.liquidity
            );
            uint256 token1LimitImpact = LiquidityAmounts.getAmount1ForLiquidity(
                position.sqrtRatioAX96,
                position.sqrtRatioBX96,
                position.liquidity
            );

            maxCollateralSupply[position.token0] -= token0LimitImpact;
            maxCollateralSupply[position.token1] -= token1LimitImpact;

            delete _positionInfo[nfts[i]];

            positionManager.transferFrom(address(this), nftsRecipient, nfts[i]);
        }

        _ownedVaults[owner].remove(vaultId);

        delete debt[vaultId];
        delete debtFee[vaultId];
        delete vaultOwner[vaultId];
        delete _vaultNfts[vaultId];
        delete _lastDebtFeeUpdateTimestamp[vaultId];
    }

    function _updateDebtFees(uint256 vaultId) internal {
        if (block.timestamp - _lastDebtFeeUpdateTimestamp[vaultId] > 0) {
            uint256 debtDelta = _calculateDebtFees(vaultId);
            if (debtDelta > 0) {
                debtFee[vaultId] += debtDelta;
            }
            _lastDebtFeeUpdateTimestamp[vaultId] = block.timestamp;
        }
    }

    event VaultOpened(address indexed origin, address indexed sender, uint256 vaultId);
    event VaultLiquidated(address indexed origin, address indexed sender, uint256 vaultId);
    event VaultClosed(address indexed origin, address indexed sender, uint256 vaultId);

    event CollateralDeposited(address indexed origin, address indexed sender, uint256 vaultId, uint256 tokenId);
    event CollateralWithdrew(address indexed origin, address indexed sender, uint256 vaultId, uint256 tokenId);

    event DebtMinted(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);
    event DebtBurned(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);

    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);
    event OracleUpdated(address indexed origin, address indexed sender, address oracleAddress);
    event TokenUpdated(address indexed origin, address indexed sender, address tokenAddress);

    event SystemPaused(address indexed origin, address indexed sender);
    event SystemUnpaused(address indexed origin, address indexed sender);

    event SystemPrivate(address indexed origin, address indexed sender);
    event SystemPublic(address indexed origin, address indexed sender);
}
