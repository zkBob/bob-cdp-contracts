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

/// @notice Contract of the system vault manager
contract Vault is DefaultAccessControl {
    /// @notice Thrown when a vault is private and a depositor is not allowed
    error AllowList();

    /// @notice Thrown when a token total value in the protocol would exceed max token capital limit (set in governance) after a deposit
    error CollateralTokenOverflow(address token);

    /// @notice Thrown when a value of a deposited NFT is less than min single nft capital (set in governance)
    error CollateralUnderflow();

    /// @notice Thrown when a pool of NFT is not in the whitelist
    error InvalidPool();

    /// @notice Thrown when a value of a stabilization fee is incorrect
    error InvalidValue();

    /// @notice Thrown when the system is paused
    error Paused();

    /// @notice Thrown when a position is healthy
    error PositionHealthy();

    /// @notice Thrown when a position is unhealthy
    error PositionUnhealthy();

    /// @notice Thrown when the MUSD token contract has already been set
    error TokenSet();

    /// @notice Thrown when a vault is tried to be closed and debt has not been paid yet
    error UnpaidDebt();

    /// @notice Thrown when the vault debt limit (which's set in governance) would been exceeded after a deposit
    error DebtLimitExceeded();

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant YEAR = 365 * 24 * 3600;
    uint256 public constant Q128 = 2**128;
    uint256 public constant Q96 = 2**96;

    /// @notice Information about a single UniV3 NFT
    /// @param token0 First token in UniswapV3 pool
    /// @param token1 Second token in UniswapV3 pool
    /// @param fee Fee of Uniswap pool
    /// @param positionKey Key of a specific position in UniswapV3 pool
    /// @param liquidity Overall liquidity in UniswapV3 position
    /// @param feeGrowthInside0LastX128 Fee growth of token0 inside the tick range as of the moment of the deposit
    /// @param feeGrowthInside1LastX128 Fee growth of token1 inside the tick range as of the moment of the deposit
    /// @param tokensOwed0 The computed amount of token0 owed to the position as of the moment of the deposit
    /// @param tokensOwed1 The computed amount of token1 owed to the position as of the moment of the deposit
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
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

    /// @notice UniswapV3 position manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice UniswapV3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Protocol governance, which controls this specific Vault
    IProtocolGovernance public immutable protocolGovernance;

    /// @notice Oracle for price estimations
    IOracle public oracle;

    /// @notice Mellow Stable Token
    IMUSD public token;

    /// @notice Vault fees treasury address
    address public immutable treasury;

    /// @notice State variable, which shows if Vault is paused or not
    bool public isPaused = false;

    /// @notice State variable, which shows if Vault is private or not
    bool public isPrivate = true;

    EnumerableSet.AddressSet private _depositorsAllowlist;
    mapping(address => EnumerableSet.UintSet) private _ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;

    /// @notice Mapping, returning vault owner by vault id
    mapping(uint256 => address) public vaultOwner;

    /// @notice Mapping, returning debt by vault id
    mapping(uint256 => uint256) public debt;

    /// @notice Mapping, returning total accumulated stabilising fees by vault id (which are due to be paid)
    mapping(uint256 => uint256) public debtFee;

    mapping(uint256 => uint256) private _lastDebtFeeUpdateTimestamp;

    /// @notice Mapping, returning last cumulative sum of debt fees by vault id
    mapping(uint256 => uint256) private _lastDebtFeeUpdateCumulativeSum;

    /// @notice Mapping, returning current maximal possible supply in NFTs for a token
    mapping(address => uint256) public maxCollateralSupply;

    mapping(uint256 => PositionInfo) private _positionInfo;

    /// @notice State variable, returning vaults quantity (gets incremented after opening a new vault)
    uint256 public vaultCount = 0;

    /// @notice Array, contatining stabilisation fee updates history
    uint256[] public stabilisationFeeUpdate;

    /// @notice Array, contatining stabilisation fee update timestamps history
    uint256[] public stabilisationFeeUpdateTimestamp;

    /// @notice State variable, returning current stabilisation fee
    uint256 public stabilisationFee;

    /// @notice State variable, returning latest timestamp of stabilisation fee update
    uint256 public lastStabilisationFeeUpdateTimestamp;

    /// @notice State variable, meaning time-weighted cumulative stabilisation fee
    uint256 public cumulativeStabilisationFeePerSecond = 0;

    /// @notice Creates a new contract
    /// @param admin Protocol admin
    /// @param positionManager_ UniswapV3 position manager
    /// @param factory_ UniswapV3 factory
    /// @param protocolGovernance_ UniswapV3 protocol governance
    /// @param oracle_ Chainlink oracle
    /// @param treasury_ Vault fees treasury
    /// @param stabilisationFee_ MUSD initial stabilisation fee
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

        stabilisationFee = stabilisationFee_;
        lastStabilisationFeeUpdateTimestamp = block.timestamp;
    }

    // -------------------   PUBLIC, VIEW   -------------------

    /// @notice Calculate health factor for a given vault
    /// @param vaultId Id of the vault
    /// @return uint256 Health factor
    function calculateHealthFactor(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            uint256 nft = _vaultNfts[vaultId].at(i);
            uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(
                address(_positionInfo[nft].targetPool)
            );
            result += _calculatePosition(nft, _positionInfo[nft], liquidationThreshold);
        }
        return result;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Get all vaults with a given owner
    /// @param target Owner address
    /// @return uint256[] Array of vaults, owned by address
    function ownedVaultsByAddress(address target) external view returns (uint256[] memory) {
        return _ownedVaults[target].values();
    }

    /// @notice Get all NFTs, managed by vault with given id
    /// @param vaultId Id of the vault
    /// @return uint256[] Array of NFTs, managed by vault
    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory) {
        return _vaultNfts[vaultId].values();
    }

    /// @notice Get all verified depositors
    /// @return address[] Array of verified depositors
    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    /// @notice Get total debt for a given vault by id (including fees)
    /// @param vaultId Id of the vault
    /// @return uint256 Total debt value
    function getOverallDebt(uint256 vaultId) external view returns (uint256) {
        return debt[vaultId] + debtFee[vaultId] + _calculateDebtFees(vaultId);
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Open a new Vault
    /// @return vaultId Id of the new vault
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

    /// @notice Close a vault
    /// @param vaultId Id of the vault
    function closeVault(uint256 vaultId) external {
        _requireVaultOwner(vaultId);
        _updateDebtFees(vaultId);

        if (debt[vaultId] != 0 || debtFee[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, msg.sender, msg.sender);

        emit VaultClosed(tx.origin, msg.sender, vaultId);
    }

    /// @notice Deposit collateral to a given vault
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
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

        if (_calculatePosition(nft, position, DENOMINATOR) < protocolGovernance.protocolParams().minSingleNftCapital) {
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

    /// @notice Withdraw collateral from a given vault
    /// @param nft UniV3 NFT to be withdrawn
    function withdrawCollateral(uint256 nft) external {
        _checkIsPaused();
        PositionInfo memory position = _positionInfo[nft];
        _requireVaultOwner(position.vaultId);
        _updateDebtFees(position.vaultId);

        uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(address(position.targetPool));
        uint256 result = calculateHealthFactor(position.vaultId) -
            _calculatePosition(nft, position, liquidationThreshold);

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

    /// @notice Mint debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount Debt amount to be mited
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

    /// @notice Burn debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount Debt amount to be burned
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

    /// @notice Liquidate a vault
    /// @param vaultId Id of the vault subject to liquidation
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
        token.transfer(owner, returnAmount - daoReceiveAmount - debt[vaultId]);
        token.burn(owner, debt[vaultId]);

        _closeVault(vaultId, owner, msg.sender);

        emit VaultLiquidated(tx.origin, msg.sender, vaultId);
    }

    /// @notice Set a new price oracle
    /// @param oracle_ New oracle
    function setOracle(IOracle oracle_) external {
        _requireAdmin();
        if (address(oracle_) == address(0)) {
            revert AddressZero();
        }
        oracle = oracle_;

        emit OracleUpdated(tx.origin, msg.sender, address(oracle));
    }

    /// @notice Set MUSD token
    /// @param token_ MUSD token
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

    /// @notice Pause the system
    function pause() external {
        _requireAtLeastOperator();
        isPaused = true;

        emit SystemPaused(tx.origin, msg.sender);
    }

    /// @notice Unpause the system
    function unpause() external {
        _requireAdmin();
        isPaused = false;

        emit SystemUnpaused(tx.origin, msg.sender);
    }

    /// @notice Make the system private
    function makePrivate() external {
        _requireAdmin();
        isPrivate = true;

        emit SystemPrivate(tx.origin, msg.sender);
    }

    /// @notice Make the system public
    function makePublic() external {
        _requireAdmin();
        isPrivate = false;

        emit SystemPublic(tx.origin, msg.sender);
    }

    /// @notice Add an array of new depositors to the allow list
    /// @param depositors Array of new depositors
    function addDepositorsToAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.add(depositors[i]);
        }
    }

    /// @notice Remove an array of depositors from the allow list
    /// @param depositors Array of new depositors
    function removeDepositorsFromAllowlist(address[] calldata depositors) external {
        _requireAdmin();
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.remove(depositors[i]);
        }
    }

    /// @notice Update stabilisation fee
    /// @param stabilisationFee_ New stabilisation fee
    function updateStabilisationFee(uint256 stabilisationFee_) external {
        _requireAdmin();
        if (stabilisationFee_ > DENOMINATOR) {
            revert InvalidValue();
        }

        uint256 delta = block.timestamp - lastStabilisationFeeUpdateTimestamp;
        cumulativeStabilisationFeePerSecond += delta * stabilisationFee;

        stabilisationFee = stabilisationFee_;
        lastStabilisationFeeUpdateTimestamp = block.timestamp;

        emit StabilisationFeeUpdated(tx.origin, msg.sender, stabilisationFee_);
    }

    // -------------------  INTERNAL, VIEW  -----------------------

    /// @notice Calculate vault capital total amount
    /// @param vaultId Vault id
    function _calculateVaultAmount(uint256 vaultId) internal view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            uint256 nft = _vaultNfts[vaultId].at(i);
            result += _calculatePosition(nft, _positionInfo[nft], DENOMINATOR);
        }
        return result;
    }

    /// @notice Get fee growth inside position
    /// @param pool UniswapV3 pool
    /// @param tickLower UniswapV3 lower tick
    /// @param tickUpper UniswapV3 upper tick
    /// @param tickCurrent UniswapV3 current tick
    /// @param feeGrowthGlobal0X128 UniswapV3 fees of token0 collected per unit of liquidity for the entire life of the pool
    /// @param feeGrowthGlobal1X128 UniswapV3 fees of token1 collected per unit of liquidity for the entire life of the pool
    /// @return feeGrowthInside0X128 - UniswapV3 feeGrowthInside0X128, feeGrowthInside1X128 - UniswapV3 feeGrowthInside1X128
    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        unchecked {
            (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool.ticks(
                tickLower
            );
            (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool.ticks(
                tickUpper
            );

            // calculate fee growth below
            uint256 feeGrowthBelow0X128;
            uint256 feeGrowthBelow1X128;
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lowerFeeGrowthOutside0X128;
                feeGrowthBelow1X128 = lowerFeeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128;
            }

            // calculate fee growth above
            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upperFeeGrowthOutside0X128;
                feeGrowthAbove1X128 = upperFeeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperFeeGrowthOutside0X128;
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperFeeGrowthOutside1X128;
            }

            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }

    /// @notice Calculate total tokens + fees for position
    /// @param pool UniswapV3 pool
    /// @param uniV3Nft UniswapV3 nft of position
    /// @return tokensOwed0 - UniswapV3 tokensOwed0 + fees, tokensOwed1 - UniswapV3 tokensOwed1 + fees
    function _calculateFees(IUniswapV3Pool pool, uint256 uniV3Nft)
        internal
        view
        returns (uint128 tokensOwed0, uint128 tokensOwed1)
    {
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        (
            ,
            ,
            ,
            ,
            ,
            tickLower,
            tickUpper,
            liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1
        ) = positionManager.positions(uniV3Nft);

        if (liquidity == 0) {
            return (tokensOwed0, tokensOwed1);
        }

        uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
        (, int24 tick, , , , , ) = pool.slot0();

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(
            pool,
            tickLower,
            tickUpper,
            tick,
            feeGrowthGlobal0X128,
            feeGrowthGlobal1X128
        );

        uint256 feeGrowthInside0DeltaX128;
        uint256 feeGrowthInside1DeltaX128;
        unchecked {
            feeGrowthInside0DeltaX128 = feeGrowthInside0X128 - feeGrowthInside0LastX128;
            feeGrowthInside1DeltaX128 = feeGrowthInside1X128 - feeGrowthInside1LastX128;
        }

        tokensOwed0 += uint128(FullMath.mulDiv(feeGrowthInside0DeltaX128, liquidity, Q128));
        tokensOwed1 += uint128(FullMath.mulDiv(feeGrowthInside1DeltaX128, liquidity, Q128));
    }

    /// @notice Calculate total capital of position
    /// @param nft UniswapV3 nft of position
    /// @param position Position info
    /// @param liquidationThreshold System liquidation threshold
    /// @return Position capital
    function _calculatePosition(
        uint256 nft,
        PositionInfo memory position,
        uint256 liquidationThreshold
    ) internal view returns (uint256) {
        uint256[] memory tokenAmounts = new uint256[](2);
        (uint160 sqrtRatioX96, , , , , , ) = position.targetPool.slot0();

        (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            position.liquidity
        );

        (uint256 tokensOwed0, uint256 tokensOwed1) = _calculateFees(position.targetPool, nft);
        tokenAmounts[0] += tokensOwed0;
        tokenAmounts[1] += tokensOwed1;

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

    /// @notice Check if caller is vault owner
    /// @param vaultId Vault id
    function _requireVaultOwner(uint256 vaultId) internal view {
        if (vaultOwner[vaultId] != msg.sender) {
            revert Forbidden();
        }
    }

    /// @notice Check if system is paused
    function _checkIsPaused() internal view {
        if (isPaused) {
            revert Paused();
        }
    }

    /// @notice Calculate debt fees for a given vault
    /// @param vaultId Vault id
    /// @return debtDelta - time accumulated debt fees
    function _calculateDebtFees(uint256 vaultId) internal view returns (uint256 debtDelta) {
        if (debt[vaultId] == 0) {
            return 0;
        }

        uint256 currentCumulativeStabilisationFeePerSecond = cumulativeStabilisationFeePerSecond +
            stabilisationFee *
            (block.timestamp - lastStabilisationFeeUpdateTimestamp);
        uint256 addedCumulativeSum = currentCumulativeStabilisationFeePerSecond -
            _lastDebtFeeUpdateCumulativeSum[vaultId];
        debtDelta = FullMath.mulDiv(debt[vaultId], addedCumulativeSum, YEAR * DENOMINATOR);
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    /// @notice Close a vault (internal)
    /// @param vaultId Id of the vault
    /// @param owner Vault owner
    /// @param nftsRecipient Address to receive nft of positions in the closed vault
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

    /// @notice Update time-dependent debt fees for a vault
    /// @param vaultId Id of the vault
    function _updateDebtFees(uint256 vaultId) internal {
        if (block.timestamp - _lastDebtFeeUpdateTimestamp[vaultId] > 0) {
            uint256 debtDelta = _calculateDebtFees(vaultId);
            if (debtDelta > 0) {
                debtFee[vaultId] += debtDelta;
            }
            _lastDebtFeeUpdateTimestamp[vaultId] = block.timestamp;
            _lastDebtFeeUpdateCumulativeSum[vaultId] =
                cumulativeStabilisationFeePerSecond +
                stabilisationFee *
                (block.timestamp - lastStabilisationFeeUpdateTimestamp);
        }
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when a new vault is being opened
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultOpened(address indexed origin, address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is being liquidated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultLiquidated(address indexed origin, address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is being closed
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultClosed(address indexed origin, address indexed sender, uint256 vaultId);

    /// @notice Emitted when a collateral is being deposited
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralDeposited(address indexed origin, address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a collateral is being withdrawn
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralWithdrew(address indexed origin, address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a debt is being minted
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtMinted(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when a debt is being burnt
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtBurned(address indexed origin, address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when the stabilisation fee is being updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param stabilisationFee New stabilisation fee
    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);

    /// @notice Emitted when the oracle is being updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param oracleAddress New oracle address
    event OracleUpdated(address indexed origin, address indexed sender, address oracleAddress);

    /// @notice Emitted when the token is being updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokenAddress New token address
    event TokenUpdated(address indexed origin, address indexed sender, address tokenAddress);

    /// @notice Emitted when the system is set to paused
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPaused(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to unpaused
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemUnpaused(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to private
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPrivate(address indexed origin, address indexed sender);

    /// @notice Emitted when the system is set to public
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event SystemPublic(address indexed origin, address indexed sender);
}
