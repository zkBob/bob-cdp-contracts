// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/mocks/EnumerableSetMock.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/external/univ3/INonfungiblePositionManager.sol";
import "./interfaces/external/univ3/IUniswapV3Pool.sol";
import "./interfaces/oracles/IOracle.sol";
import "./utils/DefaultAccessControl.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./interfaces/external/univ3/IUniswapV3Factory.sol";
import "./libraries/ExceptionsLibrary.sol";
import "./libraries/CommonLibrary.sol";
import "./libraries/external/LiquidityAmounts.sol";
import "./libraries/external/FullMath.sol";
import "./libraries/external/TickMath.sol";

// todo: add stabilisation fee

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

    bool public isPaused = false;
    bool public isPrivate = false;
    INonfungiblePositionManager public immutable positionManager;
    IOracle public oracle;
    IUniswapV3Factory public immutable factory;
    IProtocolGovernance public protocolGovernance;
    EnumerableSet.AddressSet private _depositorsAllowlist;
    IERC20 public immutable token;
    mapping(address => EnumerableSet.UintSet) public ownedVaults;
    mapping(uint256 => EnumerableSet.UintSet) public vaultNfts;
    mapping(uint256 => address) public vaultOwners;
    mapping(uint256 => uint256) public debt;
    mapping(uint256 => PositionInfo) private _positionInfo;
    address public immutable treasury;
    uint256 vaultCount = 0;

    function ownedVaults(address target) external view returns (uint256[] memory) {
        return ownedVaults[target].values();
    }

    function depositorsAllowlist() external view returns (address[] memory) {
        return _depositorsAllowlist.values();
    }

    function openVault() external returns (uint256 vaultId) {
        require(
            !isPrivate || _depositorsAllowlist.contains(msg.sender),
            ExceptionsLibrary.ALLOWLIST
        );
        ++vaultCount;
        ownedVaults[msg.sender].add(vaultCount);
        vaultOwners[vaultCount] = msg.sender;
        return vaultCount;
    }

    function closeVault(uint256 vaultId) external {
        require(vaultOwner[vaultId] == msg.sender, ExceptionsLibrary.FORBIDDEN);
        require(debt[vaultId] == 0, ExceptionsLibrary.UNPAID_DEBT);
        _closeVault(vaultId, msg.sender, msg.sender);
    }

    function _closeVault(uint256 vaultId, address vaultOwner, address nftsRecipient) internal {
        uint256[] memory nfts = vaultNfts[];

        for (uint256 i = 0; i < nfts.length(); ++i) {
            // todo: add limits support
            delete _positionInfo[nfts[i]];
            positionManager.safeTransferFrom(address(this), nftsRecipient, nfts[i]);
        }

        delete debt[vaultId];
        ownedVaults[vaultOwner].remove(vaultId);
        delete vaultOwners[vaultId];
        delete vaultNfts[vaultId];
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
        require(
            !isPrivate || _depositorsAllowlist.contains(msg.sender),
            ExceptionsLibrary.ALLOWLIST
        );
        require(vaultOwner[vaultId] == msg.sender, ExceptionsLibrary.FORBIDDEN);
        (,,
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
        IUniswapV3Pool pool = factory.getPool(token0, token1, fee);
        require(protocolGovernance.isPoolWhitelisted(address(pool)), ExceptionsLibrary.INVALID_POOL);

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

        // todo: check limits

        vaultNfts[vaultId].add(nft);
    }

    function withdrawCollateral(uint256 nft) external {
        PositionInfo memory position = _positionInfo[nft];
        require(vaultOwner[vaultId] == msg.sender, ExceptionsLibrary.FORBIDDEN);

        uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(position.targetPool);
        uint256 result = calculateHealthFactor(position.vaultId) - _calculatePosition(nft, liquidationThreshold);

        // checking that health factor is more or equal than 1
        require(result >= debt[position.vaultId], ExceptionsLibrary.LIMIT_UNDERFLOW);

        positionManager.safeTransferFrom(address(this), msg.sender, nft);

        vaultNfts.remove(nft);
        delete _positionInfo[nft];
    }

    function calculateHealthFactor(uint256 vaultId) public view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < vaultNfts[vaultId].length(); ++i) {
            uint256 nft = vaultNfts[vaultId].at(i);
            uint256 liquidationThreshold = protocolGovernance.liquidationThreshold(position.targetPool);
            result += _calculatePosition(_positionInfo[nft], liquidationThreshold);
        }
        return result;
    }

    function _calculateVaultAmount(uint256 vaultId) internal view returns (uint256) {
        uint256 result = 0;
        for (uint256 i = 0; i < vaultNfts[vaultId].length(); ++i) {
            uint256 nft = vaultNfts[vaultId].at(i);
            result += _calculatePosition(_positionInfo[nft], DENOMINATOR);
        }
        return result;
    }

    function _calculatePosition(PositionInfo memory position, uint256 liquidationThreshold) internal view returns (uint256) {
        tokenAmounts = new uint256[](2);
        (uint160 sqrtPriceX96, , , , , , ) = position.targetPool.slot0();

        (tokenAmounts[0], tokenAmounts[1]) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            position.sqrtPriceAX96,
            position.sqrtPriceBX96,
            position.liquidity
        );

        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = position.targetPool.positions(position.positionKey);

        tokenAmounts[0] += position.tokensOwed0 + uint128(
            FullMath.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                CommonLibrary.Q128
            )
        );

        tokenAmounts[1] += position.tokensOwed1 + uint128(
            FullMath.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                CommonLibrary.Q128
            )
        );

        uint256 pricesX96 = new uint256[](2);
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
        require(vaultOwner[vaultId] == msg.sender, ExceptionsLibrary.FORBIDDEN);
        uint256 healthFactor = calculateHealthFactor(vaultId);
        require(healthFactor > debt[vaultId] + amount, ExceptionsLibrary.LIMIT_OVERFLOW);
        token.mint(msg.sender, amount);
        debt[vaultId] += amount;
    }

    function burnDebt(uint256 vaultId, uint256 amount) external {
        require(vaultOwner[vaultId] == msg.sender, ExceptionsLibrary.FORBIDDEN);
        require(debt[vaultId] >= amount, ExceptionsLibrary.LIMIT_OVERFLOW);
        token.burn(msg.sender, amount);
        debt[vaultId] -= amount;
    }

    function liquidate(uint256 vaultId) external {
        uint256 healthFactor = calculateHealthFactor(vaultId);
        require(healthFactor < debt[vaultId], ExceptionsLibrary.LIMIT_UNDERFLOW);

        uint256 vaultAmount = _calculateVaultAmount(vaultId);
        uint256 returnAmount = FullMath.mulDiv(DENOMINATOR - protocolGovernance.protocolParams().liquidationPremium, vaultAmount, DENOMINATOR);
        token.transferFrom(
            msg.sender,
            address(this),
            returnAmount
        );

        uint256 daoReceiveAmount = FullMath.mulDiv(protocolGovernance.protocolParams().liquidationFee);
        token.transfer(treasury, daoReceiveAmount);
        token.transfer(vaultOwners[i], returnAmount - daoRecieveAmount  - debt[vaultId]);

        _closeVault(vaultId, vaultOwners[vaultId], msg.sender);
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
