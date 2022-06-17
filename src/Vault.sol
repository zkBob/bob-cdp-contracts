// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/mocks/EnumerableSetMock.sol";
import "./interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./interfaces/external/univ3/IUniswapV3Pool.sol";
import "./interfaces/oracles/IOracle.sol";
import "./utils/DefaultAccessControl.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./interfaces/IMUSD.sol";
import "./interfaces/external/univ3/IUniswapV3Factory.sol";
import "./libraries/ExceptionsLibrary.sol";
import "./libraries/CommonLibrary.sol";
import "./libraries/external/LiquidityAmounts.sol";
import "./libraries/external/FullMath.sol";
import "./libraries/external/TickMath.sol";

contract Vault is DefaultAccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    uint256 public constant DENOMINATOR = 10**9;

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
        uint160 sqrtPriceAX96;
        uint160 sqrtPriceBX96;
        IUniswapV3Pool targetPool;
        uint256 vaultId;
    }

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    IProtocolGovernance public protocolGovernance;
    IOracle public oracle;
    IMUSD public immutable token;
    address public immutable treasury;

    bool public isPaused = false;
    bool public isPrivate = true;

    EnumerableSet.AddressSet private _depositorsAllowlist;
    mapping(address => EnumerableSet.UintSet) private _ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) private _vaultNfts;
    mapping(uint256 => address) public vaultOwners;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => PositionInfo) private _positionInfo;

    uint256 vaultCount = 0;

    constructor(
        address admin,
        INonfungiblePositionManager positionManager_,
        IUniswapV3Factory factory_,
        IProtocolGovernance protocolGovernance_,
        IOracle oracle_,
        IMUSD token_,
        address treasury_
    ) DefaultAccessControl(admin) {
        positionManager = positionManager_;
        factory = factory_;
        protocolGovernance = protocolGovernance_;
        oracle = oracle_;
        token = token_;
        treasury = treasury_;
    }

    function ownedVaultsByAddress(address target) external view returns (uint256[] memory) {
        return _ownedVaults[target].values();
    }

    function vaultNftsById(uint256 vaultId) external view returns (uint256[] memory) {
        return _vaultNfts[vaultId].values();
    }

    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    function openVault() external returns (uint256 vaultId) {
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert ExceptionsLibrary.AllowList();
        }

        ++vaultCount;
        _ownedVaults[msg.sender].add(vaultCount);
        vaultOwners[vaultCount] = msg.sender;

        return vaultCount;
    }

    function closeVault(uint256 vaultId) external {
        _requireVaultOwner(vaultId);

        if (debt[vaultId] != 0) {
            revert ExceptionsLibrary.UnpaidDebt();
        }

        _closeVault(vaultId, msg.sender, msg.sender);
    }

    function _closeVault(
        uint256 vaultId,
        address vaultOwner,
        address nftsRecipient
    ) internal {
        uint256[] memory nfts = _vaultNfts[vaultId].values();

        for (uint256 i = 0; i < _vaultNfts[vaultId].length(); ++i) {
            // todo: add limits support
            delete _positionInfo[nfts[i]];

            positionManager.safeTransferFrom(address(this), nftsRecipient, nfts[i]);
        }

        _ownedVaults[vaultOwner].remove(vaultId);
        delete debt[vaultId];
        delete vaultOwners[vaultId];
        delete _vaultNfts[vaultId];
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

    function depositCollateral(uint256 vaultId, uint256 nft) external {
        if (isPrivate && !_depositorsAllowlist.contains(msg.sender)) {
            revert ExceptionsLibrary.AllowList();
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
            IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

            if (!protocolGovernance.isPoolWhitelisted(address(pool))) {
                revert ExceptionsLibrary.InvalidPool();
            }

            positionManager.transferFrom(msg.sender, address(this), nft);

            PositionInfo memory position = PositionInfo({
                token0: token0,
                token1: token1,
                fee: fee,
                positionKey: keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper)),
                liquidity: liquidity,
                feeGrowthInside0LastX128: feeGrowthInside0LastX128,
                feeGrowthInside1LastX128: feeGrowthInside1LastX128,
                tokensOwed0: tokensOwed0,
                tokensOwed1: tokensOwed1,
                sqrtPriceAX96: TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceBX96: TickMath.getSqrtRatioAtTick(tickUpper),
                targetPool: pool,
                vaultId: vaultId
            });

            _positionInfo[nft] = position;
        }

        // todo: check limits

        _vaultNfts[vaultId].add(nft);
    }

    function withdrawCollateral(uint256 nft) external {
        PositionInfo memory position = _positionInfo[nft];
        _requireVaultOwner(position.vaultId);

        uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(address(position.targetPool));
        uint256 result = calculateHealthFactor(position.vaultId) - _calculatePosition(position, liquidationThreshold);

        // checking that health factor is more or equal than 1
        if (result < debt[position.vaultId]) {
            revert ExceptionsLibrary.PositionUnhealthy();
        }

        positionManager.safeTransferFrom(address(this), msg.sender, nft);

        _vaultNfts[position.vaultId].remove(nft);
        delete _positionInfo[nft];
    }

    function _updateDebt(uint256 vaultId) internal {}

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
        (uint160 sqrtPriceX96, , , , , , ) = position.targetPool.slot0();

        (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            position.sqrtPriceAX96,
            position.sqrtPriceBX96,
            position.liquidity
        );

        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = position.targetPool.positions(
            position.positionKey
        );

        tokenAmounts[0] +=
            position.tokensOwed0 +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    position.liquidity,
                    CommonLibrary.Q128
                )
            );

        tokenAmounts[1] +=
            position.tokensOwed1 +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    position.liquidity,
                    CommonLibrary.Q128
                )
            );

        uint256[] memory pricesX96 = new uint256[](2);
        pricesX96[0] = oracle.price(position.token0);
        pricesX96[1] = oracle.price(position.token1);

        uint256 result = 0;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 tokenAmountsUSD = FullMath.mulDiv(tokenAmounts[i], pricesX96[i], CommonLibrary.Q96);
            result += FullMath.mulDiv(tokenAmountsUSD, liquidationThreshold, DENOMINATOR);
        }

        return result;
    }

    function mintDebt(uint256 vaultId, uint256 amount) external {
        _requireVaultOwner(vaultId);
        uint256 healthFactor = calculateHealthFactor(vaultId);

        if (healthFactor < debt[vaultId] + amount) {
            revert ExceptionsLibrary.PositionUnhealthy();
        }

        token.mint(msg.sender, amount);
        debt[vaultId] += amount;
    }

    function burnDebt(uint256 vaultId, uint256 amount) external {
        _requireVaultOwner(vaultId);

        if (amount > debt[vaultId]) {
            revert ExceptionsLibrary.DebtOverflow();
        }

        token.burn(msg.sender, amount);
        debt[vaultId] -= amount;
    }

    function liquidate(uint256 vaultId) external {
        uint256 healthFactor = calculateHealthFactor(vaultId);
        if (healthFactor >= debt[vaultId]) {
            revert ExceptionsLibrary.PositionHealthy();
        }

        uint256 vaultAmount = _calculateVaultAmount(vaultId);
        uint256 returnAmount = FullMath.mulDiv(
            DENOMINATOR - protocolGovernance.protocolParams().liquidationPremium,
            vaultAmount,
            DENOMINATOR
        );
        token.transferFrom(msg.sender, address(this), returnAmount);

        uint256 daoReceiveAmount = FullMath.mulDiv(
            protocolGovernance.protocolParams().liquidationFee,
            vaultAmount,
            DENOMINATOR
        );
        token.transfer(treasury, daoReceiveAmount);
        token.transfer(vaultOwners[vaultId], returnAmount - daoReceiveAmount - debt[vaultId]);

        _closeVault(vaultId, vaultOwners[vaultId], msg.sender);
    }

    function _requireVaultOwner(uint256 vaultId) internal view {
        if (vaultOwners[vaultId] != msg.sender) {
            revert ExceptionsLibrary.Forbidden();
        }
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
}
