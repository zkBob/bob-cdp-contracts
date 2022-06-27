// SPDX-License-Identifier: UNLICENSED
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
    error AllowList();
    error CollateralTokenOverflow(address token);
    error CollateralUnderflow();
    error DebtOverflow();
    error InvalidPool();
    error Paused();
    error PositionHealthy();
    error PositionUnhealthy();
    error TokenSet();
    error UnpaidDebt();

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant YEAR = 365 * 24 * 3600;
    uint256 public constant Q128 = 2**128;
    uint256 public constant Q96 = 2**96;

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

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    IProtocolGovernance public immutable protocolGovernance;
    IOracle public oracle;
    IMUSD public token;
    address public immutable treasury;

    bool public isPaused = false;
    bool public isPrivate = true;

    EnumerableSet.AddressSet private _depositorsAllowlist;
    mapping(address => EnumerableSet.UintSet) private _ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;
    mapping(uint256 => address) public vaultOwner;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => uint256) public debtFee;
    mapping(uint256 => uint256) private _lastDebtFeeUpdateTimestamp;
    mapping(address => uint256) public maxCollateralSupply;
    mapping(uint256 => PositionInfo) private _positionInfo;

    uint256 public vaultCount = 0;

    constructor(
        address admin,
        INonfungiblePositionManager positionManager_,
        IUniswapV3Factory factory_,
        IProtocolGovernance protocolGovernance_,
        IOracle oracle_,
        address treasury_
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

    // -------------------  EXTERNAL, MUTATING  -------------------

    function openVault() external returns (uint256 vaultId) {
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        ++vaultCount;
        _ownedVaults[msg.sender].add(vaultCount);
        vaultOwner[vaultCount] = msg.sender;
        _lastDebtFeeUpdateTimestamp[vaultCount] = block.timestamp;

        return vaultCount;
    }

    function closeVault(uint256 vaultId) external {
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        if (debt[vaultId] != 0 || debtFee[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, msg.sender, msg.sender);
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
    }

    function mintDebt(uint256 vaultId, uint256 amount) external {
        _checkIsPaused();
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        uint256 healthFactor = calculateHealthFactor(vaultId);

        if (healthFactor < debt[vaultId] + debtFee[vaultId] + amount) {
            revert PositionUnhealthy();
        }

        token.mint(msg.sender, amount);
        debt[vaultId] += amount;
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
    }

    function setOracle(IOracle oracle_) external {
        _requireAdmin();
        if (address(oracle_) == address(0)) {
            revert AddressZero();
        }
        oracle = oracle_;
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
    }

    function pause() external {
        _requireAtLeastOperator();
        isPaused = true;
    }

    function unpause() external {
        _requireAdmin();
        isPaused = false;
    }

    function makePrivate() external {
        _requireAdmin();
        isPrivate = true;
    }

    function makePublic() external {
        _requireAdmin();
        isPrivate = false;
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
        uint256 timeElapsed = block.timestamp - _lastDebtFeeUpdateTimestamp[vaultId];
        if (timeElapsed > 0) {
            if (debt[vaultId] > 0) {
                uint256 factor = FullMath.mulDiv(
                    timeElapsed,
                    protocolGovernance.protocolParams().stabilizationFee,
                    YEAR
                );
                debtDelta = FullMath.mulDiv(debt[vaultId], factor, DENOMINATOR);
            }
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
}
