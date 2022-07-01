// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./utils/DefaultAccessControl.sol";

contract ProtocolGovernance is IProtocolGovernance, ERC165, DefaultAccessControl {
    /// @notice Thrown when a value is not valid.
    error InvalidValue();

    /// @notice Thrown when a pool address is not valid.
    error InvalidPool();

    /// @notice Thrown when a value is equal to zero.
    error ValueZero();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant TOKEN_DECIMALS = 18;
    uint256 public constant MAX_LIQUIDATION_FEE_RATE = (DENOMINATOR / 100) * 10;
    uint256 public constant MAX_PERCENTAGE_RATE = DENOMINATOR;
    uint256 public constant MAX_NFT_CAPITAL_LIMIT_USD = 200_000;

    EnumerableSet.AddressSet private _whitelistedPools;

    ProtocolParams private _protocolParams;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public liquidationThreshold;

    mapping(address => bool) private _isTokenCapitalLimited;

    mapping(address => uint256) private _tokenCapitalLimit;

    /// @notice Creates a new contract.
    /// @param admin Protocol admin
    constructor(address admin) DefaultAccessControl(admin) {
        _protocolParams.maxDebtPerVault = type(uint256).max;
    }

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @inheritdoc IProtocolGovernance
    function protocolParams() external view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    /// @inheritdoc IProtocolGovernance
    function isPoolWhitelisted(address pool) external view returns (bool) {
        return (_whitelistedPools.contains(pool));
    }

    /// @inheritdoc IProtocolGovernance
    function getTokenLimit(address token) external view returns (uint256) {
        if (!_isTokenCapitalLimited[token]) {
            return type(uint256).max;
        }
        return _tokenCapitalLimit[token];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165, AccessControlEnumerable)
        returns (bool)
    {
        return (interfaceId == type(IProtocolGovernance).interfaceId) || super.supportsInterface(interfaceId);
    }

    // -------------------  EXTERNAL, MUTATING  -------------------

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationFee(uint256 liquidationFee) external {
        _requireAdmin();
        if (liquidationFee > MAX_LIQUIDATION_FEE_RATE) {
            revert InvalidValue();
        }
        _protocolParams.liquidationFee = liquidationFee;
        emit LiquidationFeeChanged(tx.origin, msg.sender, liquidationFee);
    }

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationPremium(uint256 liquidationPremium) external {
        _requireAdmin();
        if (liquidationPremium > MAX_LIQUIDATION_FEE_RATE) {
            revert InvalidValue();
        }
        _protocolParams.liquidationPremium = liquidationPremium;
        emit LiquidationPremiumChanged(tx.origin, msg.sender, liquidationPremium);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external {
        _requireAdmin();
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
        emit MaxDebtPerVaultChanged(tx.origin, msg.sender, maxDebtPerVault);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMinSingleNftCapital(uint256 minSingleNftCapital) external {
        _requireAdmin();
        if (minSingleNftCapital > MAX_NFT_CAPITAL_LIMIT_USD * (10**TOKEN_DECIMALS)) {
            revert InvalidValue();
        }
        _protocolParams.minSingleNftCapital = minSingleNftCapital;
        emit MinSingleNftCapitalChanged(tx.origin, msg.sender, minSingleNftCapital);
    }

    /// @inheritdoc IProtocolGovernance
    function setWhitelistedPool(address pool) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert AddressZero();
        }
        _whitelistedPools.add(pool);
        emit WhitelistedPoolSet(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function revokeWhitelistedPool(address pool) external {
        _requireAdmin();
        _whitelistedPools.remove(pool);
        liquidationThreshold[pool] = 0;
        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function setLiquidationThreshold(address pool, uint256 liquidationRatio) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert AddressZero();
        }
        if (!_whitelistedPools.contains(pool)) {
            revert InvalidPool();
        }
        if (liquidationRatio > DENOMINATOR) {
            revert InvalidValue();
        }

        liquidationThreshold[pool] = liquidationRatio;
        emit LiquidationThresholdSet(tx.origin, msg.sender, pool, liquidationRatio);
    }

    /// @inheritdoc IProtocolGovernance
    function setTokenLimit(address token, uint256 newLimit) external {
        _requireAdmin();
        if (token == address(0)) {
            revert AddressZero();
        }

        _isTokenCapitalLimited[token] = true;
        _tokenCapitalLimit[token] = newLimit;
        emit TokenLimitSet(tx.origin, msg.sender, token, newLimit);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when liquidation fee is being reset.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationFee The new liquidation fee
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 liquidationFee);

    /// @notice Emitted when liquidation premium is being reset.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param liquidationPremium The new liquidation premium
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 liquidationPremium);

    /// @notice Emitted when max debt per vault is being reset.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param maxDebtPerVault The new max debt per vault
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 maxDebtPerVault);

    /// @notice Emitted when min nft capital is being reset.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param minSingleNftCapital The new min nft capital
    event MinSingleNftCapitalChanged(address indexed origin, address indexed sender, uint256 minSingleNftCapital);

    /// @notice Emitted when liquidation threshold for a specific pool is being set.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The given pool
    /// @param liquidationRatio The new liquidation ratio
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address pool,
        uint256 liquidationRatio
    );

    /// @notice Emitted when new pool is being added to the whitelist.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The new whitelisted pool
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address pool);

    /// @notice Emitted when pool is being deleted from the whitelist.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param pool The deleted whitelisted pool
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address pool);

    /// @notice Emitted when token capital limit is being set.
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param token The token address
    /// @param stagedLimit The new token capital limit
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
}
