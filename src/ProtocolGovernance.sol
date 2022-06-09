// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;


import "./interfaces/IProtocolGovernance.sol";
import "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import "./utils/DefaultAccessControl.sol";
import "src/libraries/CommonLibrary.sol";
import "./utils/ContractMeta.sol";

contract ProtocolGovernance is ContractMeta, IProtocolGovernance, ERC165, DefaultAccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DENOMINATOR = 10**9;
    uint256 public constant MAX_GOVERNANCE_DELAY = 3 days;
    uint256 public constant MAX_LIQUIDATION_FEE_RATE = (DENOMINATOR / 100) * 10;
    uint256 public constant MAX_PERCENTAGE_RATE = DENOMINATOR;

    EnumerableSet.AddressSet private _whitelistedPools;
    EnumerableSet.AddressSet private _stagedWhitelistedPools;

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
    mapping(address => mapping(address => bool)) public isTokenPairTotalCapitalLimited;

    /// @inheritdoc IProtocolGovernance
    mapping(address => mapping(address => uint256)) public tokenPairTotalCapitalLimits;

    constructor(address admin) DefaultAccessControl(admin) {}

    // -------------------  EXTERNAL, VIEW  -------------------

    /// @inheritdoc IProtocolGovernance
    function protocolParams() public view returns (ProtocolParams memory) {
        return _protocolParams;
    }

    /// @inheritdoc IProtocolGovernance
    function stagedProtocolParams() public view returns (ProtocolParams memory) {
        return _stagedProtocolParams;
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
    function stageLiquidationThreshold(address pool, uint256 liquidationRatio) external {

        _requireAdmin();
        require(pool != address(0), ExceptionsLibrary.ADDRESS_ZERO);
        require(liquidationRatio > 0, ExceptionsLibrary.ADDRESS_ZERO);

        uint256 usageTimestamp = block.timestamp + _protocolParams.governanceDelay;

        stagedLiquidationThreshold[pool] = liquidationRatio;
        stagedLiquidationThresholdTimestamp[pool] = block.timestamp + _protocolParams.governanceDelay;
        emit LiquidationRatioStaged(tx.origin, msg.sender, pool, liquidationRatio, usageTimestamp);
    }

    /// @inheritdoc IProtocolGovernance
    function stagePairTokensLimit(address token0, address token1, uint256 newLimit) external {
        require(token0 != address(0), ExceptionsLibrary.ADDRESS_ZERO);
        require(token1 != address(0), ExceptionsLibrary.ADDRESS_ZERO);
        require(token0 != token1, ExceptionsLibrary.DUPLICATE);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        isTokenPairTotalCapitalLimited[token0][token1] = true;
        tokenPairTotalCapitalLimits[token0][token1] = newLimit;
        emit PairTokensLimitStaged(tx.origin, msg.sender, token0, token1, newLimit);
    }

    /// @inheritdoc IProtocolGovernance
    function commitParams() external {
        _requireAdmin();
        require(stagedParamsTimestamp != 0, ExceptionsLibrary.NULL);
        require(
            block.timestamp >= stagedParamsTimestamp,
            ExceptionsLibrary.TIMESTAMP
        );
        _protocolParams = _stagedProtocolParams;
        delete _stagedProtocolParams;
        delete stagedParamsTimestamp;
        emit ParamsCommitted(tx.origin, msg.sender, _protocolParams);
    }

    /// @inheritdoc IProtocolGovernance
    function commitLiquidationThreshold(address pool) external {
        _requireAdmin();
        uint256 commitTime = stagedLiquidationThresholdTimestamp[pool];
        require(commitTime != 0, ExceptionsLibrary.ADDRESS_ZERO);
        require(commitTime <= block.timestamp, ExceptionsLibrary.TIMESTAMP);
        liquidationThreshold[pool] = stagedLiquidationThreshold[pool];
        delete stagedLiquidationThreshold[pool];
        delete stagedLiquidationThresholdTimestamp[pool];
        emit LiquidationRatioCommited(tx.origin, msg.sender, pool);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    function _contractName() internal pure override returns (bytes32) {
        return bytes32("ProtocolGovernance");
    }

    function _contractVersion() internal pure override returns (bytes32) {
        return bytes32("1.0.0");
    }

    function _validateGovernanceParams(ProtocolParams calldata newParams) private pure {
        require(newParams.governanceDelay <= MAX_GOVERNANCE_DELAY);
        require(newParams.stabilizationFee <= MAX_PERCENTAGE_RATE);
        require(newParams.liquidationFee <= MAX_LIQUIDATION_FEE_RATE);
        require(newParams.liquidationPremium <= MAX_LIQUIDATION_FEE_RATE);
    }

    // --------------------------  EVENTS  --------------------------

    event ParamsStaged(address indexed origin, address indexed sender, uint256 usageTimestamp, ProtocolParams params);
    event ParamsCommitted(address indexed origin, address indexed sender, ProtocolParams params);
    event LiquidationRatioStaged(address indexed origin, address indexed sender, address indexed pool, uint256 liquidationRatio, uint256 usageTimestamp);
    event LiquidationRatioCommited(address indexed origin, address indexed sender, address indexed pool);
    event PairTokensLimitStaged(address indexed origin, address indexed sender, address token0, address token1, uint256 stagedLimit);

}