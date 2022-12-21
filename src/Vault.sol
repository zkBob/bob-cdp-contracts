// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
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
import "./proxy/EIP1967Admin.sol";
import "./utils/VaultAccessControl.sol";

/// @notice Contract of the system vault manager
contract Vault is EIP1967Admin, VaultAccessControl, ERC721Enumerable, IERC721Receiver {
    /// @notice Thrown when a vault is private and a depositor is not allowed
    error AllowList();

    /// @notice Thrown when a value of a deposited NFT is less than min single nft capital (set in governance)
    error CollateralUnderflow();

    /// @notice Thrown when a vault has already been initialized
    error Initialized();

    /// @notice Thrown when a pool of NFT is not in the whitelist
    error InvalidPool();

    /// @notice Thrown when a value of a stabilization fee is incorrect
    error InvalidValue();

    /// @notice Thrown when no Chainlink oracle is added for one of tokens of a deposited Uniswap V3 NFT
    error MissingOracle();

    /// @notice Thrown when the nft limit for one vault would have been exceeded after the deposit
    error NFTLimitExceeded();

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
    uint256 public constant Q48 = 2**48;

    /// @notice Information about a single UniV3 NFT
    /// @param token0 The first token in the UniswapV3 pool
    /// @param token1 The second token in the UniswapV3 pool
    /// @param targetPool Address of the UniswapV3 pool, which contains collateral position
    /// @param vaultId Id of Mellow Vault, which takes control over collateral nft
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    struct UniV3PositionInfo {
        address token0;
        address token1;
        IUniswapV3Pool targetPool;
        uint256 vaultId;
        uint160 sqrtRatioAX96;
        uint160 sqrtRatioBX96;
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
    IMUSD public immutable token;

    /// @notice Vault fees treasury address
    address public immutable treasury;

    /// @notice State variable, which shows if Vault is initialized or not
    bool public isInitialized;

    /// @notice State variable, which shows if Vault is paused or not
    bool public isPaused;

    /// @notice State variable, which shows if Vault is public or not
    bool public isPublic;

    /// @notice Address set, containing only accounts, which are allowed to make deposits
    EnumerableSet.AddressSet private _depositorsAllowlist;

    /// @notice Mapping, returning set of all nfts, managed by vault
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;

    /// @notice Mapping, returning debt by vault id (in MUSD weis)
    mapping(uint256 => uint256) public vaultDebt;

    /// @notice Mapping, returning total accumulated stabilising fees by vault id (which are due to be paid)
    mapping(uint256 => uint256) public stabilisationFeeVaultSnapshot;

    /// @notice Mapping, returning timestamp of latest debt fee update, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _stabilisationFeeVaultSnapshotTimestamp;

    /// @notice Mapping, returning last cumulative sum of time-weighted debt fees by vault id, generated during last deposit / withdraw / mint / burn
    mapping(uint256 => uint256) private _globalStabilisationFeePerUSDVaultSnapshotD;

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
    /// @param positionManager_ UniswapV3 position manager
    /// @param factory_ UniswapV3 factory
    /// @param protocolGovernance_ UniswapV3 protocol governance
    /// @param treasury_ Vault fees treasury
    constructor(
        string memory name,
        string memory symbol,
        INonfungiblePositionManager positionManager_,
        IUniswapV3Factory factory_,
        IProtocolGovernance protocolGovernance_,
        address treasury_,
        address token_
    ) ERC721(name, symbol) {
        if (
            address(positionManager_) == address(0) ||
            address(factory_) == address(0) ||
            address(protocolGovernance_) == address(0) ||
            address(treasury_) == address(0) ||
            address(token_) == address(0)
        ) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        factory = factory_;
        protocolGovernance = protocolGovernance_;
        treasury = treasury_;
        token = IMUSD(token_);
        isInitialized = true;
    }

    /// @notice Initialized a new contract.
    /// @param admin Protocol admin
    /// @param oracle_ Oracle
    /// @param stabilisationFee_ MUSD initial stabilisation fee
    function initialize(
        address admin,
        IOracle oracle_,
        uint256 stabilisationFee_
    ) external {
        if (isInitialized) {
            revert Initialized();
        }

        if (admin == address(0)) {
            revert AddressZero();
        }

        if (address(oracle_) == address(0)) {
            revert AddressZero();
        }

        if (stabilisationFee_ > DENOMINATOR) {
            revert InvalidValue();
        }

        _setupRole(OPERATOR, admin);
        _setupRole(ADMIN_ROLE, admin);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ADMIN_DELEGATE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR, ADMIN_DELEGATE_ROLE);

        oracle = oracle_;

        // initial value
        stabilisationFeeRateD = stabilisationFee_;
        globalStabilisationFeePerUSDSnapshotTimestamp = block.timestamp;
        isInitialized = true;
    }

    // -------------------   PUBLIC, VIEW   -------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerable, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC721Receiver).interfaceId == interfaceId;
    }

    /// @notice Calculate adjusted collateral for a given vault (token capitals of each specific collateral in the vault in MUSD weis)
    /// @param vaultId Id of the vault
    /// @return uint256 Adjusted collateral
    function calculateVaultAdjustedCollateral(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        uint256[] memory nfts = _vaultNfts[vaultId].values();

        INonfungiblePositionManager positionManager_ = positionManager;
        IProtocolGovernance protocolGovernance_ = protocolGovernance;

        for (uint256 i = 0; i < nfts.length; ++i) {
            uint256 nft = nfts[i];
            UniV3PositionInfo memory position = _uniV3PositionInfo[nft];
            uint256 liquidationThresholdD = protocolGovernance_.liquidationThresholdD(address(position.targetPool));
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
            ) = positionManager_.positions(nft);

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
        uint256 currentDebt = vaultDebt[vaultId];
        return currentDebt + stabilisationFeeVaultSnapshot[vaultId] + _accruedStabilisationFee(vaultId, currentDebt);
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Get all vaults with a given owner
    /// @param target Owner address
    /// @return result Array of vaults` ids, owned by address
    function ownedVaultsByAddress(address target) external view returns (uint256[] memory result) {
        uint256 nftsCount = balanceOf(target);
        result = new uint256[](nftsCount);
        for (uint256 i = 0; i < nftsCount; ++i) {
            result[i] = tokenOfOwnerByIndex(target, i);
        }
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
    function openVault() public onlyUnpaused returns (uint256 vaultId) {
        if (!isPublic && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        vaultId = vaultCount + 1;
        vaultCount = vaultId;

        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();

        _mint(msg.sender, vaultId);

        emit VaultOpened(msg.sender, vaultId);
    }

    /// @notice Close a vault
    /// @param vaultId Id of the vault
    /// @param collateralRecipient The address of collateral recipient
    function closeVault(uint256 vaultId, address collateralRecipient) external onlyUnpaused {
        _requireVaultOwner(vaultId);

        if (vaultDebt[vaultId] + stabilisationFeeVaultSnapshot[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, collateralRecipient);

        emit VaultClosed(msg.sender, vaultId);
    }

    /// @notice Deposit collateral to a given vault
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
    function depositCollateral(uint256 vaultId, uint256 nft) public {
        positionManager.safeTransferFrom(msg.sender, address(this), nft, abi.encode(vaultId));
    }

    /// @notice Withdraw collateral from a given vault
    /// @param nft UniV3 NFT to be withdrawn
    function withdrawCollateral(uint256 nft) external {
        UniV3PositionInfo memory position = _uniV3PositionInfo[nft];
        _requireVaultOwner(position.vaultId);

        _vaultNfts[position.vaultId].remove(nft);

        positionManager.transferFrom(address(this), msg.sender, nft);

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
    function mintDebt(uint256 vaultId, uint256 amount) public onlyUnpaused {
        _requireVaultOwner(vaultId);
        _updateVaultStabilisationFee(vaultId);

        token.mint(msg.sender, amount);
        vaultDebt[vaultId] += amount;
        uint256 overallVaultDebt = stabilisationFeeVaultSnapshot[vaultId] + vaultDebt[vaultId];

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

        address owner = ownerOf(vaultId);

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

        _closeVault(vaultId, msg.sender);

        emit VaultLiquidated(msg.sender, vaultId);
    }

    function mintDebtFromScratch(uint256 nft, uint256 amount) external returns (uint256 vaultId) {
        vaultId = openVault();
        depositCollateral(vaultId, nft);
        mintDebt(vaultId, amount);
    }

    function depositAndMint(
        uint256 vaultId,
        uint256 nft,
        uint256 amount
    ) external {
        depositCollateral(vaultId, nft);
        mintDebt(vaultId, amount);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) external onlyUnpaused returns (bytes4) {
        if (msg.sender != address(positionManager)) {
            revert Forbidden();
        }
        uint256 vaultId = abi.decode(data, (uint256));

        _depositCollateral(from, vaultId, tokenId);

        return this.onERC721Received.selector;
    }

    /// @notice Set a new price oracle
    /// @param oracle_ The new oracle
    function setOracle(IOracle oracle_) external onlyVaultAdmin {
        if (address(oracle_) == address(0)) {
            revert AddressZero();
        }
        oracle = oracle_;

        emit OracleUpdated(tx.origin, msg.sender, address(oracle));
    }

    /// @notice Pause the system
    function pause() external onlyAtLeastOperator {
        isPaused = true;

        emit SystemPaused(tx.origin, msg.sender);
    }

    /// @notice Unpause the system
    function unpause() external onlyVaultAdmin {
        isPaused = false;

        emit SystemUnpaused(tx.origin, msg.sender);
    }

    /// @notice Make the system private
    function makePrivate() external onlyVaultAdmin {
        isPublic = false;

        emit SystemPrivate(tx.origin, msg.sender);
    }

    /// @notice Make the system public
    function makePublic() external onlyVaultAdmin {
        isPublic = true;

        emit SystemPublic(tx.origin, msg.sender);
    }

    /// @notice Add an array of new depositors to the allow list
    /// @param depositors Array of new depositors
    function addDepositorsToAllowlist(address[] calldata depositors) external onlyVaultAdmin {
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.add(depositors[i]);
        }
    }

    /// @notice Remove an array of depositors from the allow list
    /// @param depositors Array of new depositors
    function removeDepositorsFromAllowlist(address[] calldata depositors) external onlyVaultAdmin {
        for (uint256 i = 0; i < depositors.length; i++) {
            _depositorsAllowlist.remove(depositors[i]);
        }
    }

    /// @notice Update stabilisation fee (multiplied by DENOMINATOR) and calculate global stabilisation fee per USD up to current timestamp using previous stabilisation fee
    /// @param stabilisationFeeRateD_ New stabilisation fee multiplied by DENOMINATOR
    function updateStabilisationFeeRate(uint256 stabilisationFeeRateD_) external onlyVaultAdmin {
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
        INonfungiblePositionManager positionManager_ = positionManager;

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
            ) = positionManager_.positions(nft);
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

        uint256[] memory pricesX96 = new uint256[](2);
        {
            bool successFirstOracle;
            bool successSecondOracle;

            (successFirstOracle, pricesX96[0]) = oracle.price(position.token0);
            (successSecondOracle, pricesX96[1]) = oracle.price(position.token1);

            if (!successFirstOracle || !successSecondOracle) {
                return 0;
            }
        }

        uint256 ratioX96 = FullMath.mulDiv(pricesX96[0], Q96, pricesX96[1]);
        uint160 sqrtRatioX96 = uint160(FullMath.sqrt(ratioX96) * Q48);

        (, int24 tick, , , , , ) = position.targetPool.slot0();

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
        if (ownerOf(vaultId) != msg.sender) {
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
    /// @return uint256 Accrued stablisation fee of the vault (in MUSD weis)
    function _accruedStabilisationFee(uint256 vaultId, uint256 currentVaultDebt) internal view returns (uint256) {
        uint256 deltaGlobalStabilisationFeeD = globalStabilisationFeePerUSDD() -
            _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];
        return FullMath.mulDiv(currentVaultDebt, deltaGlobalStabilisationFeeD, DENOMINATOR);
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    /// @notice Completes deposit of a collateral to vault
    /// @param caller Caller address
    /// @param vaultId Id of the vault
    /// @param nft UniV3 NFT to be deposited
    function _depositCollateral(
        address caller,
        uint256 vaultId,
        uint256 nft
    ) internal {
        if (!isPublic && !_depositorsAllowlist.contains(caller)) {
            revert AllowList();
        }

        if (protocolGovernance.protocolParams().maxNftsPerVault <= _vaultNfts[vaultId].length()) {
            revert NFTLimitExceeded();
        }

        _requireMinted(vaultId);

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

            {
                uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
                uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

                _uniV3PositionInfo[nft] = UniV3PositionInfo({
                    token0: token0,
                    token1: token1,
                    targetPool: IUniswapV3Pool(factory.getPool(token0, token1, fee)),
                    vaultId: vaultId,
                    sqrtRatioAX96: sqrtRatioAX96,
                    sqrtRatioBX96: sqrtRatioBX96
                });

                if (!protocolGovernance.isPoolWhitelisted(factory.getPool(token0, token1, fee))) {
                    revert InvalidPool();
                }

                if (!oracle.hasOracle(token0) || !oracle.hasOracle(token1)) {
                    revert MissingOracle();
                }
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

        _vaultNfts[vaultId].add(nft);

        emit CollateralDeposited(caller, vaultId, nft);
    }

    /// @notice Close a vault (internal)
    /// @param vaultId Id of the vault
    /// @param nftsRecipient Address to receive nft of the positions in the closed vault
    function _closeVault(uint256 vaultId, address nftsRecipient) internal {
        uint256[] memory nfts = _vaultNfts[vaultId].values();
        INonfungiblePositionManager positionManager_ = positionManager;

        for (uint256 i = 0; i < nfts.length; ++i) {
            uint256 nft = nfts[i];

            delete _uniV3PositionInfo[nft];

            positionManager_.transferFrom(address(this), nftsRecipient, nft);
        }

        delete vaultDebt[vaultId];
        delete stabilisationFeeVaultSnapshot[vaultId];
        delete _vaultNfts[vaultId];
        delete _stabilisationFeeVaultSnapshotTimestamp[vaultId];
        delete _globalStabilisationFeePerUSDVaultSnapshotD[vaultId];

        _burn(vaultId);
    }

    /// @notice Update stabilisation fee for a given vault (in MUSD weis)
    /// @param vaultId Id of the vault
    function _updateVaultStabilisationFee(uint256 vaultId) internal {
        uint256 currentVaultDebt = vaultDebt[vaultId];
        if (block.timestamp == _stabilisationFeeVaultSnapshotTimestamp[vaultId]) {
            return;
        }

        stabilisationFeeVaultSnapshot[vaultId] += _accruedStabilisationFee(vaultId, currentVaultDebt);
        _stabilisationFeeVaultSnapshotTimestamp[vaultId] = block.timestamp;
        _globalStabilisationFeePerUSDVaultSnapshotD[vaultId] = globalStabilisationFeePerUSDD();
    }

    // -----------------------  MODIFIERS  --------------------------

    modifier onlyVaultAdmin() {
        _requireAdmin();
        _;
    }

    modifier onlyAtLeastOperator() {
        _requireAtLeastOperator();
        _;
    }

    modifier onlyUnpaused() {
        _requireUnpaused();
        _;
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
