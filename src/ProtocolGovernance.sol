// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./utils/DefaultAccessControl.sol";

contract ProtocolGovernance is IProtocolGovernance, ERC165, DefaultAccessControl {
    error InvalidValue();
    error InvalidPool();
    error ValueZero();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;

    EnumerableSet.AddressSet private _whitelistedPools;

    ProtocolParams private _protocolParams;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public liquidationThresholdD;

    mapping(address => uint256) private _tokenCapitalLimit;

    constructor(address admin, uint256 maxDebtPerVault) DefaultAccessControl(admin) {
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
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
        uint256 limit = _tokenCapitalLimit[token];
        if (limit == 0) {
            return type(uint256).max;
        }
        return limit;
    }

    function whitelistedPool(uint256 i) external view returns (address) {
        return _whitelistedPools.at(i);
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
    function changeLiquidationFee(uint256 liquidationFeeD) external {
        _requireAdmin();
        if (liquidationFeeD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationFeeD = liquidationFeeD;
        emit LiquidationFeeChanged(tx.origin, msg.sender, liquidationFeeD);
    }

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationPremium(uint256 liquidationPremiumD) external {
        _requireAdmin();
        if (liquidationPremiumD > DENOMINATOR) {
            revert InvalidValue();
        }
        _protocolParams.liquidationPremiumD = liquidationPremiumD;
        emit LiquidationPremiumChanged(tx.origin, msg.sender, liquidationPremiumD);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMaxDebtPerVault(uint256 maxDebtPerVault) external {
        _requireAdmin();
        _protocolParams.maxDebtPerVault = maxDebtPerVault;
        emit MaxDebtPerVaultChanged(tx.origin, msg.sender, maxDebtPerVault);
    }

    /// @inheritdoc IProtocolGovernance
    function changeMinSingleNftCollateral(uint256 minSingleNftCollateral) external {
        _requireAdmin();
        _protocolParams.minSingleNftCollateral = minSingleNftCollateral;
        emit MinSingleNftCollateralChanged(tx.origin, msg.sender, minSingleNftCollateral);
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
        liquidationThresholdD[pool] = 0;
        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function setLiquidationThreshold(address pool, uint256 liquidationThresholdD_) external {
        _requireAdmin();
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

    /// @inheritdoc IProtocolGovernance
    function setTokenLimit(address token, uint256 newLimit) external {
        _requireAdmin();
        if (token == address(0)) {
            revert AddressZero();
        }

        _tokenCapitalLimit[token] = newLimit;
        emit TokenLimitSet(tx.origin, msg.sender, token, newLimit);
    }

    // --------------------------  EVENTS  --------------------------

    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 liquidationFeeD);
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 liquidationPremiumD);
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 maxDebtPerVault);
    event MinSingleNftCollateralChanged(address indexed origin, address indexed sender, uint256 minSingleNftCollateral);
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address pool,
        uint256 liquidationThresholdD_
    );
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address pool);
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address pool);
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
}
