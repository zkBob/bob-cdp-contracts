// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/external/chainlink/IAggregatorV3.sol";
import "../interfaces/oracles/IOracle.sol";
import "../libraries/external/FullMath.sol";
import "../utils/DefaultAccessControl.sol";

/// @notice Contract for getting chainlink data
contract ChainlinkOracle is IOracle, DefaultAccessControl {
    error InvalidValue();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DECIMALS = 18;
    uint256 public constant Q96 = 2**96;

    /// @notice Mapping, returning oracle by it`s token.
    mapping(address => address) public oraclesIndex;

    /// @notice Mapping, returning decimals by it`s token.
    mapping(address => uint256) public decimalsIndex;
    EnumerableSet.AddressSet private _tokens;

    /// @notice Creates a new contract.
    /// @param tokens Tokens, managed by the oracles
    /// @param oracles Initial Chainlink oracles
    /// @param admin Oracles admin
    constructor(
        address[] memory tokens,
        address[] memory oracles,
        address admin
    ) DefaultAccessControl(admin) {
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  EXTERNAL, VIEW  ------------------------------

    /// @notice Return, if token has been added to oracles or not.
    /// @param token A given token address
    function hasOracle(address token) external view returns (bool) {
        return _tokens.contains(token);
    }

    /// @notice Get all tokens, supported by the oracles.
    /// @return Array of supported tokens
    function supportedTokens() external view returns (address[] memory) {
        return _tokens.values();
    }

    /// @inheritdoc IOracle
    function price(address token) external view returns (uint256 priceX96) {
        priceX96 = 0;
        IAggregatorV3 chainlinkOracle = IAggregatorV3(oraclesIndex[token]);
        if (address(chainlinkOracle) == address(0)) {
            return priceX96;
        }
        uint256 priceNumerator;
        bool success;
        (success, priceNumerator) = _queryChainlinkOracle(chainlinkOracle);
        if (!success) {
            return priceX96;
        }

        uint256 decimals = decimalsIndex[token];
        uint256 priceDenominator = 1;

        if (DECIMALS > decimals) {
            priceNumerator *= 10**(DECIMALS - decimals);
        } else if (decimals > DECIMALS) {
            priceDenominator *= 10**(decimals - DECIMALS);
        }
        priceX96 = FullMath.mulDiv(priceNumerator, Q96, priceDenominator);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId) || interfaceId == type(IOracle).interfaceId;
    }

    // -------------------------  EXTERNAL, MUTATING  ------------------------------

    /// @notice Add more chainlink oracles and tokens, managed by them.
    /// @param tokens Array of new tokens
    /// @param oracles Array of new oracles
    function addChainlinkOracles(address[] memory tokens, address[] memory oracles) external {
        _requireAdmin();
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    function _queryChainlinkOracle(IAggregatorV3 oracle) internal view returns (bool success, uint256 answer) {
        try oracle.latestRoundData() returns (uint80, int256 ans, uint256, uint256, uint80) {
            return (true, uint256(ans));
        } catch (bytes memory) {
            return (false, 0);
        }
    }

    // -------------------------  INTERNAL, MUTATING  ------------------------------

    function _addChainlinkOracles(address[] memory tokens, address[] memory oracles) internal {
        if (tokens.length != oracles.length) {
            revert InvalidValue();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address oracle = oracles[i];
            _tokens.add(token);
            oraclesIndex[token] = oracle;
            decimalsIndex[token] = uint256(IERC20Metadata(token).decimals() + IAggregatorV3(oracle).decimals());
        }
        emit OraclesAdded(tx.origin, msg.sender, tokens, oracles);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when new Chainlink oracle is added
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokens Tokens added
    /// @param oracles Orecles added for the tokens
    event OraclesAdded(address indexed origin, address indexed sender, address[] tokens, address[] oracles);
}
