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
    uint256 public constant MAX_GOVERNANCE_DELAY = 3 days;
    uint256 public constant MAX_LIQUIDATION_FEE_RATE = (DENOMINATOR / 100) * 10;
    uint256 public constant MAX_PERCENTAGE_RATE = DENOMINATOR;

    EnumerableSet.AddressSet private _whitelistedPools;

    ProtocolParams private _protocolParams;
    ProtocolParams private _stagedProtocolParams;

    /// @inheritdoc IProtocolGovernance
    uint256 public stagedParamsTimestamp;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public liquidationThreshold;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public stagedLiquidationThreshold;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public stagedLiquidationThresholdTimestamp;

    /// @inheritdoc IProtocolGovernance
    mapping(address => uint256) public stagedWhitelistedPoolTimestamp;

    /// @inheritdoc IProtocolGovernance
    mapping(address => mapping(address => bool)) public isTokenPairTotalCapitalLimited;

    /// @inheritdoc IProtocolGovernance
    mapping(address => mapping(address => uint256)) public tokenPairTotalCapitalLimits;

    constructor(address admin) DefaultAccessControl(admin) {}

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @inheritdoc IProtocolGovernance
    function protocolParams() external view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    /// @inheritdoc IProtocolGovernance
    function stagedProtocolParams() external view returns (ProtocolParams memory) {
        return _stagedProtocolParams;
    }

    function isPoolWhitelisted(address pool) external view returns (bool) {
        return (_whitelistedPools.contains(pool));
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
    function stageParams(ProtocolParams calldata newParams) external {
        _requireAdmin();

        _validateGovernanceParams(newParams);
        _stagedProtocolParams = newParams;
        stagedParamsTimestamp = block.timestamp + _protocolParams.governanceDelay;

        emit ParamsStaged(tx.origin, msg.sender, stagedParamsTimestamp, _stagedProtocolParams);
    }

    /// @inheritdoc IProtocolGovernance
    function commitParams() external {
        _requireAdmin();

        if (stagedParamsTimestamp == 0) {
            revert ExceptionsLibrary.Null();
        }

        if (stagedParamsTimestamp > block.timestamp) {
            revert ExceptionsLibrary.Timestamp();
        }

        _protocolParams = _stagedProtocolParams;

        delete _stagedProtocolParams;
        delete stagedParamsTimestamp;

        emit ParamsCommitted(tx.origin, msg.sender, _protocolParams);
    }

    function stageWhitelistedPool(address pool) external {
        _requireAdmin();

        if (pool == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }

        uint256 usageTimestamp = block.timestamp + _protocolParams.governanceDelay;

        stagedWhitelistedPoolTimestamp[pool] = usageTimestamp;

        emit WhitelistedPoolStaged(tx.origin, msg.sender, pool, usageTimestamp);
    }

    function commitWhitelistedPool(address pool) external {
        _requireAdmin();
        uint256 commitTime = stagedWhitelistedPoolTimestamp[pool];

        if (commitTime == 0) {
            revert ExceptionsLibrary.Null();
        }

        if (commitTime > block.timestamp) {
            revert ExceptionsLibrary.Timestamp();
        }

        _whitelistedPools.add(pool);

        delete stagedWhitelistedPoolTimestamp[pool];

        emit WhitelistedPoolCommited(tx.origin, msg.sender, pool);
    }

    function revokeWhitelistedPool(address pool) external {
        _requireAdmin();
        _whitelistedPools.remove(pool);

        emit WhitelistedPoolRevoked(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function stageLiquidationThreshold(address pool, uint256 liquidationRatio) external {
        _requireAdmin();

        if (pool == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }

        if (liquidationRatio == 0) {
            revert ExceptionsLibrary.ValueZero();
        }

        uint256 usageTimestamp = block.timestamp + _protocolParams.governanceDelay;

        stagedLiquidationThreshold[pool] = liquidationRatio;
        stagedLiquidationThresholdTimestamp[pool] = usageTimestamp;

        emit LiquidationRatioStaged(tx.origin, msg.sender, pool, liquidationRatio, usageTimestamp);
    }

    /// @inheritdoc IProtocolGovernance
    function commitLiquidationThreshold(address pool) external {
        _requireAdmin();
        uint256 commitTime = stagedLiquidationThresholdTimestamp[pool];

        if (commitTime == 0) {
            revert ExceptionsLibrary.Null();
        }

        if (commitTime > block.timestamp) {
            revert ExceptionsLibrary.Timestamp();
        }

        liquidationThreshold[pool] = stagedLiquidationThreshold[pool];

        delete stagedLiquidationThreshold[pool];
        delete stagedLiquidationThresholdTimestamp[pool];

        emit LiquidationRatioCommited(tx.origin, msg.sender, pool);
    }

    /// @inheritdoc IProtocolGovernance
    function stagePairTokensLimit(
        address token0,
        address token1,
        uint256 newLimit
    ) external {
        if (token0 == address(0) || token1 == address(0)) {
            revert ExceptionsLibrary.AddressZero();
        }
        if (token0 == token1) {
            revert ExceptionsLibrary.Duplicate();
        }

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        isTokenPairTotalCapitalLimited[token0][token1] = true;
        tokenPairTotalCapitalLimits[token0][token1] = newLimit;

        emit PairTokensLimitStaged(tx.origin, msg.sender, token0, token1, newLimit);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    function _validateGovernanceParams(ProtocolParams calldata newParams) private pure {
        if (
            newParams.governanceDelay > MAX_GOVERNANCE_DELAY ||
            newParams.stabilizationFee > MAX_PERCENTAGE_RATE ||
            newParams.liquidationFee > MAX_LIQUIDATION_FEE_RATE ||
            newParams.liquidationPremium > MAX_LIQUIDATION_FEE_RATE
        ) {
            revert ExceptionsLibrary.InvalidValue();
        }
    }

    // --------------------------  EVENTS  --------------------------

    event ParamsStaged(address indexed origin, address indexed sender, uint256 usageTimestamp, ProtocolParams params);
    event ParamsCommitted(address indexed origin, address indexed sender, ProtocolParams params);
    event LiquidationRatioStaged(
        address indexed origin,
        address indexed sender,
        address indexed pool,
        uint256 liquidationRatio,
        uint256 usageTimestamp
    );
    event LiquidationRatioCommited(address indexed origin, address indexed sender, address indexed pool);
    event WhitelistedPoolStaged(
        address indexed origin,
        address indexed sender,
        address indexed pool,
        uint256 usageTimestamp
    );
    event WhitelistedPoolCommited(address indexed origin, address indexed sender, address indexed pool);
    event WhitelistedPoolRevoked(address indexed origin, address indexed sender, address indexed pool);
    event PairTokensLimitStaged(
        address indexed origin,
        address indexed sender,
        address token0,
        address token1,
        uint256 stagedLimit
    );
}
