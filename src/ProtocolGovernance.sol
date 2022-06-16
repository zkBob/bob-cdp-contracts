// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces/IProtocolGovernance.sol";
import "./utils/DefaultAccessControl.sol";
import "src/libraries/CommonLibrary.sol";

contract ProtocolGovernance is IProtocolGovernance, ERC165, DefaultAccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant MAX_LIQUIDATION_FEE_RATE = (DENOMINATOR / 100) * 10;
    uint256 public constant MAX_PERCENTAGE_RATE = DENOMINATOR;
    uint256 public constant MAX_NFT_CAPITAL_LIMIT = 200_000;

    EnumerableSet.AddressSet private _whitelistedPools;

    ProtocolParams private _protocolParams;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public liquidationThreshold;

    /// @inheritdoc IProtocolGovernance
    mapping(address => bool) public isTokenCapitalLimited;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public tokenCapitalLimit;

    constructor(address admin) DefaultAccessControl(admin) {}

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @inheritdoc IProtocolGovernance
    function protocolParams() external view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    function isPoolWhitelisted(address pool) external view returns (bool) {
        return (_whitelistedPools.contains(pool));
    }

    function getTokenLimit(address token) external view returns (uint256) {
        if (!isTokenCapitalLimited[token]) {
            return type(uint256).max;
        }
        return tokenCapitalLimit[token];
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
    function setParams(ProtocolParams calldata newParams) external {
        _requireAdmin();
        _validateGovernanceParams(newParams);
        _protocolParams = newParams;
        emit ParamsSet(tx.origin, msg.sender, newParams);
    }

    /// @inheritdoc IProtocolGovernance
    function changeStabilizationFee(uint256 stabilizationFee) external {
        _requireAdmin();
        if (stabilizationFee > MAX_PERCENTAGE_RATE) {
            revert ExceptionsLibrary.InvalidValue();
        }
        _protocolParams.stabilizationFee = stabilizationFee;
        emit StabilizationFeeChanged(tx.origin, msg.sender, stabilizationFee);
    }

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationFee(uint256 liquidationFee) external {
        _requireAdmin();
        if (liquidationFee > MAX_LIQUIDATION_FEE_RATE) {
            revert ExceptionsLibrary.InvalidValue();
        }
        _protocolParams.liquidationFee = liquidationFee;
        emit LiquidationFeeChanged(tx.origin, msg.sender, liquidationFee);
    }

    /// @inheritdoc IProtocolGovernance
    function changeLiquidationPremium(uint256 liquidationPremium) external {
        _requireAdmin();
        if (liquidationPremium > MAX_LIQUIDATION_FEE_RATE) {
            revert ExceptionsLibrary.InvalidValue();
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
        if (minSingleNftCapital > MAX_NFT_CAPITAL_LIMIT) {
            revert ExceptionsLibrary.InvalidValue();
        }
        _protocolParams.minSingleNftCapital = minSingleNftCapital;
        emit MinSingleNftCapitalChanged(tx.origin, msg.sender, minSingleNftCapital);
    }

    /// @inheritdoc IProtocolGovernance
    function setWhitelistedPool(address pool) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }
        _whitelistedPools.add(pool);
        emit WhitelistedPoolSet(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function revokeWhitelistedPool(address pool) external {
        _requireAdmin();
        _whitelistedPools.remove(pool);
        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function setLiquidationThreshold(address pool, uint256 liquidationRatio) external {
        _requireAdmin();
        if (pool == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }
        if (liquidationRatio == 0) {
            revert ExceptionsLibrary.ValueZero();
        }
        if (liquidationRatio > DENOMINATOR) {
            revert ExceptionsLibrary.InvalidValue();
        }

        liquidationThreshold[pool] = liquidationRatio;
        emit LiquidationThresholdSet(tx.origin, msg.sender, pool, liquidationRatio);
    }

    /// @inheritdoc IProtocolGovernance
    function setTokenLimit(address token, uint256 newLimit) external {
        if (token == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }

        isTokenCapitalLimited[token] = true;
        tokenCapitalLimit[token] = newLimit;
        emit TokenLimitSet(tx.origin, msg.sender, token, newLimit);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    function _validateGovernanceParams(ProtocolParams calldata newParams) private pure {
        if (
            (newParams.stabilizationFee > MAX_PERCENTAGE_RATE) ||
            (newParams.liquidationFee > MAX_LIQUIDATION_FEE_RATE) ||
            (newParams.liquidationPremium > MAX_LIQUIDATION_FEE_RATE) ||
            (newParams.minSingleNftCapital > MAX_NFT_CAPITAL_LIMIT)
        ) {
            revert ExceptionsLibrary.InvalidValue();
        }
    }

    // --------------------------  EVENTS  --------------------------

    event ParamsSet(address indexed origin, address indexed sender, ProtocolParams params);
    event StabilizationFeeChanged(address indexed origin, address indexed sender, uint256 indexed stabilizationFee);
    event LiquidationFeeChanged(address indexed origin, address indexed sender, uint256 indexed liquidationFee);
    event LiquidationPremiumChanged(address indexed origin, address indexed sender, uint256 indexed liquidationPremium);
    event MaxDebtPerVaultChanged(address indexed origin, address indexed sender, uint256 indexed maxDebtPerVault);
    event MinSingleNftCapitalChanged(
        address indexed origin,
        address indexed sender,
        uint256 indexed minSingleNftCapital
    );
    event LiquidationThresholdSet(
        address indexed origin,
        address indexed sender,
        address indexed pool,
        uint256 liquidationRatio
    );
    event WhitelistedPoolSet(address indexed origin, address indexed sender, address indexed pool);
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address indexed pool);
    event TokenLimitSet(address indexed origin, address indexed sender, address token, uint256 stagedLimit);
}
