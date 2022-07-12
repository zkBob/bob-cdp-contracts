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
import "./libraries/UniswapV3FeesCalculation.sol";
import "./utils/DefaultAccessControl.sol";

/// @notice Contract of the system vault manager
contract Vault is DefaultAccessControl {
    /// @notice Thrown when a vault is private and a depositor is not allowed
    error AllowList();

    /// @notice Thrown when a max token total value in the protocol would exceed max token capital limit (set in governance) after a deposit
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
    error TokenAlreadySet();

    /// @notice Thrown when a vault is tried to be closed and debt has not been paid yet
    error UnpaidDebt();

    /// @notice Thrown when the vault debt limit (which's set in governance) would been exceeded after a deposit
    error DebtLimitExceeded();

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant YEAR = 365 * 24 * 3600;
    uint256 public constant Q96 = 2**96;

    /// @notice Information about a single UniV3 NFT
    /// @param targetPool Address of UniswapV3 pool, which contains collateral position
    /// @param vaultId Id of Mellow Vault, which takes control over collateral nft
    /// @param maxToken0Amount The maximum amount of token 0 for this position
    /// @param maxToken1Amount The maximum amount of token 1 for this position
    struct UniV3PositionInfo {
        address token0;
        address token1;
        IUniswapV3Pool targetPool;
        uint256 vaultId;
        uint160 sqrtRatioAX96;
        uint160 sqrtRatioBX96;
        uint256 maxToken0Amount;
        uint256 maxToken1Amount;
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

    /// @notice Address set, containing only accounts, which are allowed to make deposits
    EnumerableSet.AddressSet private _depositorsAllowlist;

    /// @notice Mapping, returning set of all vault ids owed by a user
    mapping(address => EnumerableSet.UintSet) private _ownedVaults;

    /// @notice Mapping, returning set of all nfts, managed by vault
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;

    /// @notice Mapping, returning vault owner by vault id
    mapping(uint256 => address) public vaultOwner;

    /// @notice Mapping, returning debt by vault id (in MUSD weis)
    mapping(uint256 => uint256) public vaultDebt;

    /// @notice Mapping, returning total accumulated stabilising fees by vault id (which are due to be paid)
    mapping(uint256 => uint256) public stabilisationFeeVaultSnapshot;

    /// @notice Mapping, returning timestamp of latest debt fee update, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _stabilisationFeeVaultSnapshotTimestamp;

    /// @notice Mapping, returning last cumulative sum of time-weighted debt fees by vault id, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _globalStabilisationFeePerUSDVaultSnapshotD;

    /// @notice Mapping, returning current maximal possible supply in NFTs for a token (in token weis)
    mapping(address => uint256) public maxCollateralSupply;

    /// @notice Mapping, returning position info by nft
    mapping(uint256 => UniV3PositionInfo) private _uniV3PositionInfo;

    /// @notice State variable, returning vaults quantity (gets incremented after opening a new vault)
    uint256 public vaultCount = 0;

    /// @notice State variable, returning current stabilisation fee (multiplied by DENOMINATOR)
    uint256 public stabilisationFeeRateD;

    /// @notice State variable, returning latest timestamp of stabilisation fee update
    uint256 public globalStabilisationFeePerUSDSnapshotTimestamp;

    /// @notice State variable, meaning time-weighted cumulative stabilisation fee
    uint256 public globalStabilisationFeePerUSDSnapshotD = 0;

    /// @notice Creates a new contract
    /// @param admin Protocol admin
    /// @param positionManager_ UniswapV3 position manager
    /// @param factory_ UniswapV3 factory
    /// @param protocolGovernance_ UniswapV3 protocol governance
    /// @param oracle_ Oracle
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

        if (stabilisationFee_ > DENOMINATOR) {
            revert InvalidValue();
        }

        positionManager = positionManager_;
        factory = factory_;
        protocolGovernance = protocolGovernance_;
        oracle = oracle_;
        treasury = treasury_;

        // initial value

        stabilisationFeeRateD = stabilisationFee_;
        globalStabilisationFeePerUSDSnapshotTimestamp = block.timestamp;
    }

    // -------------------   PUBLIC, VIEW   -------------------

    /// @notice Calculate adjusted collateral for a given vault (token capitals of each specific collateral in the vault in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return uint256 Adjusted collateral
    function calculateVaultAdjustedCollateral(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        uint256[] memory nfts = _vaultNfts[vaultId].values();
        for (uint256 i = 0; i < nfts.length; ++i) {
            uint256 nft = nfts[i];
            UniV3PositionInfo memory position = _uniV3PositionInfo[nft];
            uint256 liquidationThresholdD = protocolGovernance.liquidationThresholdD(address(position.targetPool));
            UniswapV3FeesCalculation.PositionInfo memory positionInfo;
            (
                ,
                ,
                ,
                ,
                ,
                positionInfo.tickLower,
                positionInfo.tickUpper,
                positionInfo.liquidity,
                positionInfo.feeGrowthInside0LastX128,
                positionInfo.feeGrowthInside1LastX128,
                positionInfo.tokensOwed0,
                positionInfo.tokensOwed1
            ) = positionManager.positions(nft);

            result += _calculateAdjustedCollateral(position, liquidationThresholdD, positionInfo);
        }
        return result;
    }

    /// @notice Get global time-weighted stabilisation fee per USD (multiplied by DENOMINATOR)
    /// @return uint256 Global stabilisation fee per USD (multiplied by DENOMINATOR)
    function globalStabilisationFeePerUSDD() public view returns (uint256) {
        return
            globalStabilisationFeePerUSDSnapshotD +
            (stabilisationFeeRateD * (block.timestamp - globalStabilisationFeePerUSDSnapshotTimestamp)) /
            YEAR;
    }

    /// @notice Get total debt for a given vault by id (including fees)
    /// @param vaultId Id of the vault
    /// @return uint256 Total debt value (in MUSD weis)
    function getOverallDebt(uint256 vaultId) public view returns (uint256) {
        return vaultDebt[vaultId] + stabilisationFeeVaultSnapshot[vaultId] + _accruedStabilisationFee(vaultId);
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

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Open a new Vault
    /// @return vaultId Id of the new vault
    function openVault() external returns (uint256 vaultId) {
        _requireUnpaused();
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        vaultId = vaultCount + 1;
        vaultCount = vaultId;

        _ownedVaults[msg.sender].add(vaultId);
        vaultOwner[vaultId] = msg.sender;

        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();

        emit VaultOpened(msg.sender, vaultId);
    }

    /// @notice Close a vault
    /// @param vaultId Id of the vault
    /// @param collateralRecipient The recipient address of collateral
    function closeVault(uint256 vaultId, address collateralRecipient) external {
        _requireUnpaused();
        _requireVaultOwner(vaultId);

        if (vaultDebt[vaultId] + stabilisationFeeVaultSnapshot[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, msg.sender, collateralRecipient);

        emit VaultClosed(msg.sender, vaultId);
    }

    /// @notice Deposit collateral to a given vault
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
    function depositCollateral(uint256 vaultId, uint256 nft) external {
        _requireUnpaused();
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        _requireVaultOwner(vaultId);

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

            positionManager.transferFrom(msg.sender, address(this), nft);
            {
                uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
                uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

                _uniV3PositionInfo[nft] = UniV3PositionInfo({
                    token0: token0,
                    token1: token1,
                    targetPool: IUniswapV3Pool(factory.getPool(token0, token1, fee)),
                    vaultId: vaultId,
                    sqrtRatioAX96: sqrtRatioAX96,
                    sqrtRatioBX96: sqrtRatioBX96,
                    maxToken0Amount: LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity),
                    maxToken1Amount: LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity)
                });
            }

            if (
                _calculateAdjustedCollateral(
                    _uniV3PositionInfo[nft],
                    DENOMINATOR,
                    UniswapV3FeesCalculation.PositionInfo({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidity: liquidity,
                        feeGrowthInside0LastX128: feeGrowthInside0LastX128,
                        feeGrowthInside1LastX128: feeGrowthInside1LastX128,
                        tokensOwed0: tokensOwed0,
                        tokensOwed1: tokensOwed1
                    })
                ) < protocolGovernance.protocolParams().minSingleNftCollateral
            ) {
                revert CollateralUnderflow();
            }
        }

        UniV3PositionInfo memory position = _uniV3PositionInfo[nft];

        if (!protocolGovernance.isPoolWhitelisted(address(position.targetPool))) {
            revert InvalidPool();
        }

        uint256 newMaxCollateralSupplyToken0 = maxCollateralSupply[position.token0] + position.maxToken0Amount;

        if (newMaxCollateralSupplyToken0 > protocolGovernance.getTokenLimit(position.token0)) {
            revert CollateralTokenOverflow(position.token0);
        }

        uint256 newMaxCollateralSupplyToken1 = maxCollateralSupply[position.token1] + position.maxToken1Amount;

        if (newMaxCollateralSupplyToken1 > protocolGovernance.getTokenLimit(position.token1)) {
            revert CollateralTokenOverflow(position.token1);
        }
        maxCollateralSupply[position.token0] = newMaxCollateralSupplyToken0;
        maxCollateralSupply[position.token1] = newMaxCollateralSupplyToken1;

        _vaultNfts[vaultId].add(nft);

        emit CollateralDeposited(msg.sender, vaultId, nft);
    }

    /// @notice Withdraw collateral from a given vault
    /// @param nft UniV3 NFT to be withdrawn
    function withdrawCollateral(uint256 nft) external {
        UniV3PositionInfo memory position = _uniV3PositionInfo[nft];
        _requireVaultOwner(position.vaultId);

        _vaultNfts[position.vaultId].remove(nft);

        positionManager.transferFrom(address(this), msg.sender, nft);

        maxCollateralSupply[position.token0] -= position.maxToken0Amount;
        maxCollateralSupply[position.token1] -= position.maxToken1Amount;

        delete _uniV3PositionInfo[nft];

        // checking that health factor is more or equal than 1
        if (calculateVaultAdjustedCollateral(position.vaultId) < getOverallDebt(position.vaultId)) {
            revert PositionUnhealthy();
        }

        emit CollateralWithdrew(msg.sender, position.vaultId, nft);
    }

    /// @notice Mint debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be mited
    function mintDebt(uint256 vaultId, uint256 amount) external {
        _requireUnpaused();
        _requireVaultOwner(vaultId);
        _updateVaultStabilisationFee(vaultId);

        token.mint(msg.sender, amount);
        vaultDebt[vaultId] += amount;

        uint256 overallVaultDebt = getOverallDebt(vaultId);
        if (calculateVaultAdjustedCollateral(vaultId) < overallVaultDebt) {
            revert PositionUnhealthy();
        }

        if (protocolGovernance.protocolParams().maxDebtPerVault < overallVaultDebt) {
            revert DebtLimitExceeded();
        }

        emit DebtMinted(msg.sender, vaultId, amount);
    }

    /// @notice Burn debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be burned
    function burnDebt(uint256 vaultId, uint256 amount) external {
        _requireVaultOwner(vaultId);
        _updateVaultStabilisationFee(vaultId);

        uint256 currentVaultDebt = vaultDebt[vaultId];
        uint256 overallDebt = stabilisationFeeVaultSnapshot[vaultId] + currentVaultDebt;
        amount = (amount < overallDebt) ? amount : overallDebt;
        uint256 overallAmount = amount;

        if (amount > currentVaultDebt) {
            uint256 burningFeeAmount = amount - currentVaultDebt;
            token.mint(treasury, burningFeeAmount);
            stabilisationFeeVaultSnapshot[vaultId] -= burningFeeAmount;
            amount -= burningFeeAmount;
        }

        token.burn(msg.sender, overallAmount);
        vaultDebt[vaultId] -= amount;

        emit DebtBurned(msg.sender, vaultId, overallAmount);
    }

    /// @notice Liquidate a vault
    /// @param vaultId Id of the vault subject to liquidation
    function liquidate(uint256 vaultId) external {
        uint256 overallDebt = getOverallDebt(vaultId);
        if (calculateVaultAdjustedCollateral(vaultId) >= overallDebt) {
            revert PositionHealthy();
        }

        address owner = vaultOwner[vaultId];

        uint256 vaultAmount = _calculateVaultCollateral(vaultId);
        uint256 returnAmount = FullMath.mulDiv(
            DENOMINATOR - protocolGovernance.protocolParams().liquidationPremiumD,
            vaultAmount,
            DENOMINATOR
        );
        uint256 currentDebt = vaultDebt[vaultId];
        if (returnAmount < currentDebt) {
            returnAmount = currentDebt;
        }
        token.transferFrom(msg.sender, address(this), returnAmount);

        token.burn(address(this), currentDebt);

        uint256 daoReceiveAmount = overallDebt -
            currentDebt +
            FullMath.mulDiv(protocolGovernance.protocolParams().liquidationFeeD, vaultAmount, DENOMINATOR);
        if (daoReceiveAmount > returnAmount - currentDebt) {
            daoReceiveAmount = returnAmount - currentDebt;
        }
        token.transfer(owner, returnAmount - currentDebt - daoReceiveAmount);
        token.transfer(treasury, daoReceiveAmount);

        _closeVault(vaultId, owner, msg.sender);

        emit VaultLiquidated(msg.sender, vaultId);
    }

    /// @notice Set a new price oracle
    /// @param oracle_ The new oracle
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
            revert TokenAlreadySet();
        }
        token = token_;

        emit TokenSet(tx.origin, msg.sender, address(token));
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

    /// @notice Update stabilisation fee (multiplied by DENOMINATOR) and calculate global stabilisation fee per USD up to current timestamp using previous stabilisation fee
    /// @param stabilisationFeeRateD_ New stabilisation fee multiplied by DENOMINATOR
    function updateStabilisationFeeRate(uint256 stabilisationFeeRateD_) external {
        _requireAdmin();
        if (stabilisationFeeRateD_ > DENOMINATOR) {
            revert InvalidValue();
        }

        uint256 delta = block.timestamp - globalStabilisationFeePerUSDSnapshotTimestamp;
        globalStabilisationFeePerUSDSnapshotD += (delta * stabilisationFeeRateD) / YEAR;

        stabilisationFeeRateD = stabilisationFeeRateD_;
        globalStabilisationFeePerUSDSnapshotTimestamp = block.timestamp;

        emit StabilisationFeeUpdated(tx.origin, msg.sender, stabilisationFeeRateD_);
    }

    // -------------------  INTERNAL, VIEW  -----------------------

    /// @notice Calculate the vault capital total amount (nominated in MUSD weis)
    /// @param vaultId Vault id
    /// @return uint256 Vault capital (nominated in MUSD weis)
    function _calculateVaultCollateral(uint256 vaultId) internal view returns (uint256) {
        uint256 result = 0;
        uint256[] memory nfts = _vaultNfts[vaultId].values();
        for (uint256 i = 0; i < nfts.length; ++i) {
            UniswapV3FeesCalculation.PositionInfo memory positionInfo;
            uint256 nft = nfts[i];
            (
                ,
                ,
                ,
                ,
                ,
                positionInfo.tickLower,
                positionInfo.tickUpper,
                positionInfo.liquidity,
                positionInfo.feeGrowthInside0LastX128,
                positionInfo.feeGrowthInside1LastX128,
                positionInfo.tokensOwed0,
                positionInfo.tokensOwed1
            ) = positionManager.positions(nft);
            result += _calculateAdjustedCollateral(_uniV3PositionInfo[nft], DENOMINATOR, positionInfo);
        }
        return result;
    }

    /// @notice Calculate total capital of the specific collateral (nominated in MUSD weis)
    /// @param position Position info
    /// @param liquidationThresholdD Liquidation threshold of the corresponding pool, set in the protocol governance (multiplied by DENOMINATOR)
    /// @param positionInfo Additional position info
    /// @return uint256 Position capital (nominated in MUSD weis)
    function _calculateAdjustedCollateral(
        UniV3PositionInfo memory position,
        uint256 liquidationThresholdD,
        UniswapV3FeesCalculation.PositionInfo memory positionInfo
    ) internal view returns (uint256) {
        uint256[] memory tokenAmounts = new uint256[](2);
        (uint160 sqrtRatioX96, int24 tick, , , , , ) = position.targetPool.slot0();

        (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            position.sqrtRatioAX96,
            position.sqrtRatioBX96,
            positionInfo.liquidity
        );

        (uint256 actualTokensOwed0, uint256 actualTokensOwed1) = UniswapV3FeesCalculation._calculateUniswapFees(
            position.targetPool,
            tick,
            positionInfo
        );

        tokenAmounts[0] += actualTokensOwed0;
        tokenAmounts[1] += actualTokensOwed1;

        uint256[] memory pricesX96 = new uint256[](2);
        (, pricesX96[0]) = oracle.price(position.token0);
        (, pricesX96[1]) = oracle.price(position.token1);

        uint256 result = 0;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 tokenAmountsUSD = FullMath.mulDiv(tokenAmounts[i], pricesX96[i], Q96);
            result += FullMath.mulDiv(tokenAmountsUSD, liquidationThresholdD, DENOMINATOR);
        }

        return result;
    }

    /// @notice Check if the caller is the vault owner
    /// @param vaultId Vault id
    function _requireVaultOwner(uint256 vaultId) internal view {
        if (vaultOwner[vaultId] != msg.sender) {
            revert Forbidden();
        }
    }

    /// @notice Check if the system is unpaused
    function _requireUnpaused() internal view {
        if (isPaused) {
            revert Paused();
        }
    }

    /// @notice Calculate accured stabilisation fee for a given vault (in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return Accured stablisation fee of the vault (in MUSD weis)
    function _accruedStabilisationFee(uint256 vaultId) internal view returns (uint256) {
        uint256 deltaGlobalStabilisationFeeD = globalStabilisationFeePerUSDD() -
            _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];
        return FullMath.mulDiv(vaultDebt[vaultId], deltaGlobalStabilisationFeeD, DENOMINATOR);
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    /// @notice Close a vault (internal)
    /// @param vaultId Id of the vault
    /// @param owner Vault owner
    /// @param nftsRecipient Address to receive nft of the positions in the closed vault
    function _closeVault(
        uint256 vaultId,
        address owner,
        address nftsRecipient
    ) internal {
        uint256[] memory nfts = _vaultNfts[vaultId].values();

        for (uint256 i = 0; i < nfts.length; ++i) {
            uint256 nft = nfts[i];
            UniV3PositionInfo memory position = _uniV3PositionInfo[nft];

            maxCollateralSupply[position.token0] -= position.maxToken0Amount;
            maxCollateralSupply[position.token1] -= position.maxToken1Amount;

            delete _uniV3PositionInfo[nft];

            positionManager.transferFrom(address(this), nftsRecipient, nft);
        }

        _ownedVaults[owner].remove(vaultId);

        delete vaultDebt[vaultId];
        delete stabilisationFeeVaultSnapshot[vaultId];
        delete vaultOwner[vaultId];
        delete _vaultNfts[vaultId];
        delete _stabilisationFeeVaultSnapshotTimestamp[vaultId];
        delete _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];
    }

    /// @notice Update stabilisation fee for a given vault (in MUSD weis)
    /// @param vaultId Id of the vault
    function _updateVaultStabilisationFee(uint256 vaultId) internal {
        if (block.timestamp == _stabilisationFeeVaultSnapshotTimestamp[vaultId]) {
            return;
        }
        uint256 debtDelta = _accruedStabilisationFee(vaultId);
        if (debtDelta > 0) {
            stabilisationFeeVaultSnapshot[vaultId] += debtDelta;
        }
        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when a new vault is opened
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultOpened(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is liquidated
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultLiquidated(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a vault is closed
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    event VaultClosed(address indexed sender, uint256 vaultId);

    /// @notice Emitted when a collateral is deposited
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralDeposited(address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a collateral is withdrawn
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    event CollateralWithdrew(address indexed sender, uint256 vaultId, uint256 tokenId);

    /// @notice Emitted when a debt is minted
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtMinted(address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when a debt is burnt
    /// @param sender Sender of the call (msg.sender)
    /// @param vaultId Id of the vault
    /// @param amount Debt amount
    event DebtBurned(address indexed sender, uint256 vaultId, uint256 amount);

    /// @notice Emitted when the stabilisation fee is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param stabilisationFee New stabilisation fee
    event StabilisationFeeUpdated(address indexed origin, address indexed sender, uint256 stabilisationFee);

    /// @notice Emitted when the oracle is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param oracleAddress New oracle address
    event OracleUpdated(address indexed origin, address indexed sender, address oracleAddress);

    /// @notice Emitted when the token is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokenAddress New token address
    event TokenSet(address indexed origin, address indexed sender, address tokenAddress);

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
