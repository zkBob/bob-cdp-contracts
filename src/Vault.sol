// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@zkbob/proxy/EIP1967Admin.sol";
import "./interfaces/oracles/IOracle.sol";
import "./interfaces/external/univ3/INonfungiblePositionLoader.sol";
import "./interfaces/IBobToken.sol";
import "./interfaces/IVaultRegistry.sol";
import "./interfaces/oracles/INFTOracle.sol";
import "./interfaces/ICDP.sol";
import "./libraries/UniswapV3FeesCalculation.sol";
import "./utils/VaultAccessControl.sol";
import "./interfaces/ITreasury.sol";

/// @notice Contract of the system vault manager
contract Vault is EIP1967Admin, VaultAccessControl, IERC721Receiver, ICDP, Multicall {
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

    /// @notice Thrown when a vault id does not exist
    error InvalidVault();

    /// @notice Thrown when liquidations are private and a liquidator is not allowed
    error LiquidatorsAllowList();

    /// @notice Thrown when the nft limit for one vault would have been exceeded after the deposit
    error NFTLimitExceeded();

    /// @notice Thrown when the system is paused
    error Paused();

    /// @notice Thrown when a position is healthy
    error PositionHealthy();

    /// @notice Thrown when a position is unhealthy
    error PositionUnhealthy();

    /// @notice Thrown when a tick deviation is out of limit
    error TickDeviation();

    /// @notice Thrown when a value is incorrectly equal to zero
    error ValueZero();

    /// @notice Thrown when a vault is tried to be closed and debt has not been paid yet
    error UnpaidDebt();

    /// @notice Thrown when a vault is tried to be closed and debt has not been paid yet
    error VaultNonEmpty();

    /// @notice Thrown when the vault debt limit (which's set in governance) would been exceeded after a deposit
    error DebtLimitExceeded();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant DEBT_DENOMINATOR = 10**18;
    uint256 public constant YEAR = 365 * 24 * 3600;

    /// @notice UniswapV3 position manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Oracle for price estimations
    INFTOracle public immutable oracle;

    /// @notice Bob Stable Token
    IBobToken public immutable token;

    /// @notice Vault fees treasury address
    ITreasury public immutable treasury;

    /// @notice Vault Registry
    IVaultRegistry public immutable vaultRegistry;

    /// @notice State variable, which shows if Vault is initialized or not
    bool public isInitialized;

    /// @notice State variable, which shows if Vault is paused or not
    bool public isPaused;

    /// @notice State variable, which shows if Vault is public or not
    bool public isPublic;

    /// @notice State variable, which shows if liquidating is public or not
    bool public isLiquidatingPublic;

    /// @notice Protocol params
    ICDP.ProtocolParams private _protocolParams;

    /// @notice Address set, containing only accounts, which are allowed to make deposits when system is private
    EnumerableSet.AddressSet private _depositorsAllowlist;

    /// @notice Address set, containing only accounts, which are allowed to liquidate when liquidations are private
    EnumerableSet.AddressSet private _liquidatorsAllowlist;

    /// @notice Set of whitelisted pools
    EnumerableSet.AddressSet private _whitelistedPools;

    /// @inheritdoc ICDP
    mapping(address => uint256) public liquidationThresholdD;

    /// @notice Mapping, returning set of all nfts, managed by vault
    mapping(uint256 => uint256[]) private _vaultNfts;

    /// @notice Mapping, returning normalized debt by vault id (in MUSD weis)
    mapping(uint256 => uint256) public vaultNormalizedDebt;

    /// @notice Mapping, returning sum of all outstanding vault debt mints
    mapping(uint256 => uint256) public vaultMintedDebt;

    /// @notice Mapping, returning owed by vault id (in MUSD weis)
    mapping(uint256 => uint256) public vaultOwed;

    /// @notice Mapping, returning id of a vault, that storing specific nft
    mapping(uint256 => uint256) public vaultIdByNft;

    /// @notice State variable, constantly increasing debt normalization rate, accounting for all accumulated stability fees
    uint216 public normalizationRate;

    /// @notice State variable, returning latest normalization rate update timestamp
    uint40 public normalizationRateUpdateTimestamp;

    /// @notice State variable, returning current stabilisation fee per second (multiplied by DEBT_DENOMINATOR)
    uint256 public stabilisationFeeRateD;

    /// @notice State variable, meaning normalized total protocol debt
    uint256 public normalizedGlobalDebt;

    /// @notice Creates a new contract
    /// @param positionManager_ UniswapV3 position manager
    /// @param oracle_ Oracle
    /// @param treasury_ Vault fees treasury
    /// @param token_ Address of token
    constructor(
        INonfungiblePositionManager positionManager_,
        INFTOracle oracle_,
        address treasury_,
        address token_,
        address vaultRegistry_
    ) {
        if (
            address(positionManager_) == address(0) ||
            address(oracle_) == address(0) ||
            address(treasury_) == address(0) ||
            address(token_) == address(0) ||
            address(vaultRegistry_) == address(0)
        ) {
            revert AddressZero();
        }

        positionManager = positionManager_;
        oracle = oracle_;
        treasury = ITreasury(treasury_);
        token = IBobToken(token_);
        vaultRegistry = IVaultRegistry(vaultRegistry_);
        isInitialized = true;
    }

    /// @notice Initialized a new contract.
    /// @param admin Protocol admin
    /// @param stabilisationFee_ MUSD initial stabilisation fee
    /// @param maxDebtPerVault Initial max possible debt to a one vault (nominated in MUSD weis)
    function initialize(
        address admin,
        uint256 stabilisationFee_,
        uint256 maxDebtPerVault
    ) external {
        if (isInitialized) {
            revert Initialized();
        }

        if (admin == address(0)) {
            revert AddressZero();
        }

        if (stabilisationFee_ > DEBT_DENOMINATOR / YEAR) {
            revert InvalidValue();
        }

        _setupRole(OPERATOR, admin);
        _setupRole(ADMIN_ROLE, admin);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ADMIN_DELEGATE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(OPERATOR, ADMIN_DELEGATE_ROLE);

        // initial value
        normalizationRate = uint216(DEBT_DENOMINATOR);
        stabilisationFeeRateD = stabilisationFee_;
        normalizationRateUpdateTimestamp = uint40(block.timestamp);
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
        isInitialized = true;
    }

    // -------------------   PUBLIC, VIEW   -------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC721Receiver).interfaceId == interfaceId;
    }

    /// @inheritdoc ICDP
    function calculateVaultCollateral(uint256 vaultId)
        public
        view
        returns (uint256 overallCollateral, uint256 adjustedCollateral)
    {
        (overallCollateral, adjustedCollateral, ) = _calculateVaultCollateral(vaultId, 0, false);
    }

    /// @inheritdoc ICDP
    function getOverallDebt(uint256 vaultId) public view returns (uint256) {
        uint256 updateTimestamp = normalizationRateUpdateTimestamp;
        uint256 globalFeesRate = normalizationRate;

        if (block.timestamp > updateTimestamp) {
            globalFeesRate += FullMath.mulDivRoundingUp(
                stabilisationFeeRateD * (block.timestamp - updateTimestamp),
                globalFeesRate,
                DEBT_DENOMINATOR
            );
        }

        return _getOverallDebt(vaultId, globalFeesRate);
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @notice Get all NFTs, managed by vault with given id
    /// @param vaultId Id of the vault
    /// @return uint256[] Array of NFTs, managed by vault
    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory) {
        return _vaultNfts[vaultId];
    }

    /// @notice Get all verified depositors
    /// @return address[] Array of verified depositors
    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    /// @notice Get all verified liquidators
    /// @return address[] Array of verified liquidators
    function liquidatorsAllowlist() external view returns (address[] memory) {
        return _liquidatorsAllowlist.values();
    }

    /// @inheritdoc ICDP
    function protocolParams() external view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    /// @inheritdoc ICDP
    function isPoolWhitelisted(address pool) external view returns (bool) {
        return _whitelistedPools.contains(pool);
    }

    /// @inheritdoc ICDP
    function whitelistedPool(uint256 i) external view returns (address) {
        return _whitelistedPools.at(i);
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @notice Open a new Vault
    /// @return vaultId Id of the new vault
    function openVault() public onlyUnpaused returns (uint256 vaultId) {
        if (!isPublic && !_depositorsAllowlist.contains(msg.sender)) {
            revert AllowList();
        }

        vaultId = vaultRegistry.mint(msg.sender);

        emit VaultOpened(msg.sender, vaultId);
    }

    /// @notice Close a vault
    /// @param vaultId Id of the vault
    /// @param collateralRecipient The address of collateral recipient
    function closeVault(uint256 vaultId, address collateralRecipient) external onlyUnpaused {
        _requireVaultAuth(vaultId);

        if (vaultNormalizedDebt[vaultId] != 0) {
            revert UnpaidDebt();
        }

        _closeVault(vaultId, collateralRecipient);

        emit VaultClosed(msg.sender, vaultId);
    }

    /// @notice Burns a vault NFT
    /// @param vaultId id of the vault NFT to burn
    function burnVault(uint256 vaultId) external onlyUnpaused {
        _requireVaultAuth(vaultId);

        if (vaultOwed[vaultId] != 0 || _vaultNfts[vaultId].length != 0) {
            revert VaultNonEmpty();
        }

        vaultRegistry.burn(vaultId);
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
        uint256 currentNormalizationRate = _updateRateFee();

        uint256 vaultId = vaultIdByNft[nft];
        _requireVaultAuth(vaultId);

        uint256[] storage vaultNfts = _vaultNfts[vaultId];
        for (uint256 i = 0; i < vaultNfts.length; i++) {
            if (vaultNfts[i] == nft) {
                if (i < vaultNfts.length - 1) {
                    vaultNfts[i] = vaultNfts[vaultNfts.length - 1];
                }
                vaultNfts.pop();
                break;
            }
        }
        delete vaultIdByNft[nft];

        positionManager.transferFrom(address(this), msg.sender, nft);

        // checking that health factor is more or equal than 1
        (, uint256 adjustedCollateral, ) = _calculateVaultCollateral(vaultId, 0, true);
        if (adjustedCollateral < _getOverallDebt(vaultId, currentNormalizationRate)) {
            revert PositionUnhealthy();
        }

        emit CollateralWithdrew(msg.sender, vaultId, nft);
    }

    /// @notice Mint debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be mited
    function mintDebt(uint256 vaultId, uint256 amount) public onlyUnpaused {
        _requireVaultAuth(vaultId);
        uint256 currentNormalizationRate = _updateRateFee();

        token.mint(msg.sender, amount);
        uint256 normalizedDebtDelta = FullMath.mulDivRoundingUp(amount, DEBT_DENOMINATOR, currentNormalizationRate);
        vaultNormalizedDebt[vaultId] += normalizedDebtDelta;
        vaultMintedDebt[vaultId] += amount;
        normalizedGlobalDebt += normalizedDebtDelta;

        uint256 overallVaultDebt = _getOverallDebt(vaultId, currentNormalizationRate);

        (, uint256 adjustedCollateral, ) = _calculateVaultCollateral(vaultId, 0, true);
        if (adjustedCollateral < overallVaultDebt) {
            revert PositionUnhealthy();
        }

        if (_protocolParams.maxDebtPerVault < overallVaultDebt) {
            revert DebtLimitExceeded();
        }

        emit DebtMinted(msg.sender, vaultId, amount);
    }

    /// @notice Burn debt on a given vault
    /// @param vaultId Id of the vault
    /// @param amount The debt amount to be burned
    function burnDebt(uint256 vaultId, uint256 amount) external {
        uint256 currentNormalizationRate = _updateRateFee();

        uint256 overallDebt = _getOverallDebt(vaultId, currentNormalizationRate);
        amount = (overallDebt < amount) ? overallDebt : amount;

        token.transferFrom(msg.sender, address(this), amount);

        uint256 mintedDebt = vaultMintedDebt[vaultId];
        uint256 tokensToBurn = FullMath.mulDivRoundingUp(mintedDebt, amount, overallDebt);

        uint256 normalizedDebtToBurn = FullMath.mulDivRoundingUp(amount, DEBT_DENOMINATOR, currentNormalizationRate);

        vaultNormalizedDebt[vaultId] -= normalizedDebtToBurn;
        normalizedGlobalDebt -= normalizedDebtToBurn;
        vaultMintedDebt[vaultId] = mintedDebt - tokensToBurn;

        token.transferAndCall(address(treasury), amount - tokensToBurn, "");
        token.burn(tokensToBurn);

        emit DebtBurned(msg.sender, vaultId, amount);
    }

    /// @inheritdoc ICDP
    function liquidate(uint256 vaultId) external {
        if (!isLiquidatingPublic && !_liquidatorsAllowlist.contains(msg.sender)) {
            revert LiquidatorsAllowList();
        }
        uint256 currentNormalizationRate = _updateRateFee();
        uint256 currentNormalizedDebt = vaultNormalizedDebt[vaultId];
        normalizedGlobalDebt -= currentNormalizedDebt;
        uint256 overallDebt = FullMath.mulDiv(currentNormalizedDebt, currentNormalizationRate, DEBT_DENOMINATOR);
        (uint256 vaultAmount, uint256 adjustedCollateral, ) = _calculateVaultCollateral(vaultId, 0, false);
        if (adjustedCollateral >= overallDebt) {
            revert PositionHealthy();
        }

        uint256 returnAmount = FullMath.mulDiv(
            DENOMINATOR - _protocolParams.liquidationPremiumD,
            vaultAmount,
            DENOMINATOR
        );

        if (returnAmount < overallDebt) {
            returnAmount = overallDebt;
        }

        token.transferFrom(msg.sender, address(this), returnAmount);

        uint256 tokensToBurn = vaultMintedDebt[vaultId];

        token.burn(tokensToBurn);

        uint256 liquidationFeeAmount = FullMath.mulDiv(vaultAmount, _protocolParams.liquidationFeeD, DENOMINATOR);
        if (liquidationFeeAmount >= returnAmount - overallDebt) {
            liquidationFeeAmount = returnAmount - overallDebt;
        } else {
            vaultOwed[vaultId] += returnAmount - overallDebt - liquidationFeeAmount;
        }

        token.transferAndCall(
            address(treasury),
            overallDebt - tokensToBurn + liquidationFeeAmount,
            abi.encode(overallDebt - tokensToBurn)
        );
        delete vaultNormalizedDebt[vaultId];
        delete vaultMintedDebt[vaultId];
        _closeVault(vaultId, msg.sender);

        emit VaultLiquidated(msg.sender, vaultId);
    }

    /// @inheritdoc ICDP
    function withdrawOwed(
        uint256 vaultId,
        address to,
        uint256 maxAmount
    ) external returns (uint256 withdrawnAmount) {
        _requireVaultAuth(vaultId);

        uint256 owed = vaultOwed[vaultId];
        withdrawnAmount = maxAmount > owed ? owed : maxAmount;

        token.transfer(to, withdrawnAmount);

        vaultOwed[vaultId] -= withdrawnAmount;
    }

    function mintDebtFromScratch(uint256 nft, uint256 amount) external returns (uint256 vaultId) {
        vaultId = openVault();
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

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 tokenId = params.tokenId;
        uint256 vaultId = vaultIdByNft[tokenId];
        _requireVaultAuth(vaultId);

        (amount0, amount1) = positionManager.decreaseLiquidity(params);

        _checkHealthOfVaultAndPosition(vaultId, tokenId);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 tokenId = params.tokenId;
        uint256 vaultId = vaultIdByNft[tokenId];
        _requireVaultAuth(vaultId);

        (amount0, amount1) = positionManager.collect(params);

        _checkHealthOfVaultAndPosition(vaultId, tokenId);
    }

    function collectAndIncreaseAmount(
        INonfungiblePositionManager.CollectParams calldata collectParams,
        INonfungiblePositionManager.IncreaseLiquidityParams calldata increaseLiquidityParams
    )
        external
        returns (
            uint256 depositedLiquidity,
            uint256 depositedAmount0,
            uint256 depositedAmount1,
            uint256 returnAmount0,
            uint256 returnAmount1
        )
    {
        uint256 tokenId = collectParams.tokenId;
        uint256 vaultId = vaultIdByNft[tokenId];
        _requireVaultAuth(vaultId);

        (returnAmount0, returnAmount1) = positionManager.collect(collectParams);

        (address token0, address token1) = oracle.getPositionTokens(increaseLiquidityParams.tokenId);

        IERC20(token0).transferFrom(msg.sender, address(this), increaseLiquidityParams.amount0Desired);
        IERC20(token1).transferFrom(msg.sender, address(this), increaseLiquidityParams.amount1Desired);

        _checkAllowance(token0, increaseLiquidityParams.amount0Desired, address(positionManager));
        _checkAllowance(token1, increaseLiquidityParams.amount1Desired, address(positionManager));

        (depositedLiquidity, depositedAmount0, depositedAmount1) = positionManager.increaseLiquidity(
            increaseLiquidityParams
        );

        if (depositedAmount0 < increaseLiquidityParams.amount0Desired) {
            IERC20(token0).transfer(msg.sender, increaseLiquidityParams.amount0Desired - depositedAmount0);
        }

        if (depositedAmount1 < increaseLiquidityParams.amount1Desired) {
            IERC20(token1).transfer(msg.sender, increaseLiquidityParams.amount1Desired - depositedAmount1);
        }

        _checkHealthOfVaultAndPosition(vaultId, tokenId);
    }

    /// @inheritdoc ICDP
    function changeLiquidationFee(uint32 liquidationFeeD) external onlyVaultAdmin {
        if (liquidationFeeD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationFeeD = liquidationFeeD;
        emit LiquidationFeeChanged(tx.origin, msg.sender, liquidationFeeD);
    }

    /// @inheritdoc ICDP
    function changeLiquidationPremium(uint32 liquidationPremiumD) external onlyVaultAdmin {
        if (liquidationPremiumD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationPremiumD = liquidationPremiumD;
        emit LiquidationPremiumChanged(tx.origin, msg.sender, liquidationPremiumD);
    }

    /// @inheritdoc ICDP
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external onlyVaultAdmin {
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
        emit MaxDebtPerVaultChanged(tx.origin, msg.sender, maxDebtPerVault);
    }

    /// @inheritdoc ICDP
    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external onlyVaultAdmin {
        _protocolParams.minSingleNftCollateral = minSingleNftCollateral;
        emit MinSingleNftCollateralChanged(tx.origin, msg.sender, minSingleNftCollateral);
    }

    /// @inheritdoc ICDP
    function changeMaxNftsPerVault(uint8 maxNftsPerVault) external onlyVaultAdmin {
        _protocolParams.maxNftsPerVault = maxNftsPerVault;
        emit MaxNftsPerVaultChanged(tx.origin, msg.sender, maxNftsPerVault);
    }

    /// @inheritdoc ICDP
    function setWhitelistedPool(address pool) external onlyVaultAdmin {
        if (pool == address(0)) {
            revert AddressZero();
        }
        _whitelistedPools.add(pool);
        emit WhitelistedPoolSet(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc ICDP
    function revokeWhitelistedPool(address pool) external onlyVaultAdmin {
        _whitelistedPools.remove(pool);
        liquidationThresholdD[pool] = 0;
        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc ICDP
    function setLiquidationThreshold(address pool, uint256 liquidationThresholdD_) external onlyVaultAdmin {
        if (pool == address(0)) {
            revert AddressZero();
        }
        if (!_whitelistedPools.contains(pool)) {
            revert InvalidPool();
        }
        if (liquidationThresholdD_ > DENOMINATOR) {
            revert InvalidValue();
        }

        liquidationThresholdD[pool] = liquidationThresholdD_;
        emit LiquidationThresholdSet(tx.origin, msg.sender, pool, liquidationThresholdD_);
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

    /// @notice Make liquidations private
    function makeLiquidationsPrivate() external onlyVaultAdmin {
        isLiquidatingPublic = false;

        emit LiquidationsPrivate(tx.origin, msg.sender);
    }

    /// @notice Make liquidations public
    function makeLiquidationsPublic() external onlyVaultAdmin {
        isLiquidatingPublic = true;

        emit LiquidationsPublic(tx.origin, msg.sender);
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

    /// @notice Add an array of new liquidators to the allow list
    /// @param liquidators Array of new liquidators
    function addLiquidatorsToAllowlist(address[] calldata liquidators) external onlyVaultAdmin {
        for (uint256 i = 0; i < liquidators.length; i++) {
            _liquidatorsAllowlist.add(liquidators[i]);
        }
    }

    /// @notice Remove an array of liquidators from the allow list
    /// @param liquidators Array of new liquidators
    function removeLiquidatorsFromAllowlist(address[] calldata liquidators) external onlyVaultAdmin {
        for (uint256 i = 0; i < liquidators.length; i++) {
            _liquidatorsAllowlist.remove(liquidators[i]);
        }
    }

    /// @notice Update stabilisation fee (multiplied by DEBT_DENOMINATOR) and calculate global stabilisation fee per USD up to current timestamp using previous stabilisation fee
    /// @param stabilisationFeeRateD_ New stabilisation fee multiplied by DEBT_DENOMINATOR
    function updateStabilisationFeeRate(uint256 stabilisationFeeRateD_) external onlyVaultAdmin {
        if (stabilisationFeeRateD_ > DEBT_DENOMINATOR / YEAR) {
            revert InvalidValue();
        }

        _updateRateFee();

        stabilisationFeeRateD = stabilisationFeeRateD_;

        emit StabilisationFeeUpdated(tx.origin, msg.sender, stabilisationFeeRateD_);
    }

    // -------------------  INTERNAL, VIEW  -----------------------

    /// @notice Get total debt for a given vault by id (including fees) with given normalization rate
    /// @param vaultId Id of the vault
    /// @param normalizationRate_ Given Normalization Rate
    /// @return uint256 Total debt value (in MUSD weis)
    function _getOverallDebt(uint256 vaultId, uint256 normalizationRate_) internal view returns (uint256) {
        return FullMath.mulDiv(vaultNormalizedDebt[vaultId], normalizationRate_, DEBT_DENOMINATOR);
    }

    /// @notice Check if the caller is authorized to manage the vault
    /// @param vaultId Vault id
    function _requireVaultAuth(uint256 vaultId) internal view {
        if (!vaultRegistry.isAuthorized(vaultId, msg.sender)) {
            revert Forbidden();
        }
    }

    /// @notice Check if the system is unpaused
    function _requireUnpaused() internal view {
        if (isPaused) {
            revert Paused();
        }
    }

    /// @notice Calculate overall collateral and adjusted collateral for a given vault (token capitals of each specific collateral in the vault in MUSD weis) and price of tokenId if it contains in vault
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    /// @param isSafe If true reverts in case
    /// @return overallCollateral Overall collateral
    /// @return adjustedCollateral Adjusted collateral
    /// @return positionAmount Price of tokenId if it contains in vault, 0 otherwise
    function _calculateVaultCollateral(
        uint256 vaultId,
        uint256 tokenId,
        bool isSafe
    )
        internal
        view
        returns (
            uint256 overallCollateral,
            uint256 adjustedCollateral,
            uint256 positionAmount
        )
    {
        uint256[] storage vaultNfts = _vaultNfts[vaultId];

        overallCollateral = 0;
        adjustedCollateral = 0;
        positionAmount = 0;

        for (uint256 i = 0; i < vaultNfts.length; ++i) {
            uint256 nft = vaultNfts[i];
            (bool deviationSafety, uint256 price, address pool) = oracle.price(nft);

            if (isSafe && !deviationSafety) {
                revert TickDeviation();
            }

            if (nft == tokenId) {
                positionAmount = price;
            }
            uint256 liquidationThreshold = liquidationThresholdD[pool];
            overallCollateral += price;
            adjustedCollateral += FullMath.mulDiv(price, liquidationThreshold, DENOMINATOR);
        }
    }

    /// @notice Checking health of specific vault and position
    /// @param vaultId Id of the vault
    /// @param tokenId Id of the token
    function _checkHealthOfVaultAndPosition(uint256 vaultId, uint256 tokenId) internal view {
        // checking that health factor is more or equal than 1
        (, uint256 adjustedCollateral, uint256 positionAmount) = _calculateVaultCollateral(vaultId, tokenId, true);
        if (adjustedCollateral < getOverallDebt(vaultId)) {
            revert PositionUnhealthy();
        }

        if (positionAmount < _protocolParams.minSingleNftCollateral) {
            revert CollateralUnderflow();
        }
    }

    // -------------------  INTERNAL, MUTATING  -------------------

    /// @notice Checks allowance of specific token to a target address and approves if allowance is too low
    /// @param targetToken Address of the token
    /// @param amount Amount to send
    /// @param target Target address
    function _checkAllowance(
        address targetToken,
        uint256 amount,
        address target
    ) internal {
        if (IERC20(targetToken).allowance(address(this), target) < amount) {
            IERC20(targetToken).approve(target, type(uint256).max);
        }
    }

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

        uint256[] storage vaultNfts = _vaultNfts[vaultId];
        if (_protocolParams.maxNftsPerVault <= vaultNfts.length) {
            revert NFTLimitExceeded();
        }

        // revert if vault NFT was burnt or is being managed by another minter
        if (vaultNfts.length == 0 && vaultRegistry.minterOf(vaultId) != address(this)) {
            revert InvalidVault();
        }

        (, uint256 positionAmount, address pool) = oracle.price(nft);

        if (!_whitelistedPools.contains(pool)) {
            revert InvalidPool();
        }

        if (positionAmount < _protocolParams.minSingleNftCollateral) {
            revert CollateralUnderflow();
        }

        vaultIdByNft[nft] = vaultId;
        vaultNfts.push(nft);

        emit CollateralDeposited(caller, vaultId, nft);
    }

    /// @notice Close a vault (internal)
    /// @param vaultId Id of the vault
    /// @param nftsRecipient Address to receive nft of the positions in the closed vault
    function _closeVault(uint256 vaultId, address nftsRecipient) internal {
        uint256[] storage vaultNfts = _vaultNfts[vaultId];

        for (uint256 i = 0; i < vaultNfts.length; ++i) {
            uint256 nft = vaultNfts[i];
            delete vaultIdByNft[nft];

            positionManager.transferFrom(address(this), nftsRecipient, nft);
        }

        delete _vaultNfts[vaultId];
    }

    /// @notice Update globalRateFee
    function _updateRateFee() internal returns (uint256 updatedNormalizationRate) {
        uint256 currentNormalizationRate = normalizationRate;
        uint256 updateTimestamp = normalizationRateUpdateTimestamp;

        if (block.timestamp == updateTimestamp) {
            return currentNormalizationRate;
        }

        uint256 normalizationRateDelta = FullMath.mulDivRoundingUp(
            stabilisationFeeRateD * (block.timestamp - updateTimestamp),
            currentNormalizationRate,
            DEBT_DENOMINATOR
        );
        uint256 unrealizedInterestToIncrease = FullMath.mulDiv(
            normalizedGlobalDebt,
            normalizationRateDelta,
            DEBT_DENOMINATOR
        );

        if (unrealizedInterestToIncrease > 0) {
            // Increasing unrealized interest
            treasury.add(unrealizedInterestToIncrease);
        }

        updatedNormalizationRate = currentNormalizationRate + normalizationRateDelta;
        normalizationRate = uint216(updatedNormalizationRate);
        normalizationRateUpdateTimestamp = uint40(block.timestamp);
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

    /// @notice Emitted when liquidations is set to private
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event LiquidationsPrivate(address indexed origin, address indexed sender);

    /// @notice Emitted when liquidations is set to public
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    event LiquidationsPublic(address indexed origin, address indexed sender);

    /// @notice Emitted when liquidation fee is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationFeeD The new liquidation fee (multiplied by DENOMINATOR)
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint32 liquidationFeeD);

    /// @notice Emitted when liquidation premium is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationPremiumD The new liquidation premium (multiplied by DENOMINATOR)
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint32 liquidationPremiumD);

    /// @notice Emitted when max debt per vault is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param maxDebtPerVault The new max debt per vault (nominated in MUSD weis)
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 maxDebtPerVault);

    /// @notice Emitted when min nft collateral is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param minSingleNftCollateral The new min nft collateral (nominated in MUSD weis)
    event MinSingleNftCollateralChanged(address indexed origin, address indexed sender, uint256 minSingleNftCollateral);

    /// @notice Emitted when min nft collateral is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param maxNftsPerVault The new max possible amount of NFTs for one vault
    event MaxNftsPerVaultChanged(address indexed origin, address indexed sender, uint8 maxNftsPerVault);

    /// @notice Emitted when liquidation threshold for a specific pool is updated
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The given pool
    /// @param liquidationThresholdD_ The new liquidation threshold (multiplied by DENOMINATOR)
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address pool,
        uint256 liquidationThresholdD_
    );

    /// @notice Emitted when new pool is added to the whitelist
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The new whitelisted pool
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address pool);

    /// @notice Emitted when pool is deleted from the whitelist
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The deleted whitelisted pool
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address pool);
}
