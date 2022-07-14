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
    /// @notice Thrown when tokens.length != oracles.length
    error InvalidLength();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DECIMALS = 18;
    uint256 public constant Q96 = 2**96;

    /// @notice Mapping, returning oracle for token
    mapping(address => address) public oraclesIndex;

    /// @notice Mapping, returning price multiplier for each  token
    mapping(address => uint256) public priceMultiplier;

    /// @notice Address set, containing tokens, supported by the oracles
    EnumerableSet.AddressSet private _tokens;

    /// @notice Creates a new contract
    /// @param tokens Initial supported tokens
    /// @param oracles Initial approved Chainlink oracles
    /// @param admin Protocol admin
    constructor(
        address[] memory tokens,
        address[] memory oracles,
        address admin
    ) DefaultAccessControl(admin) {
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  EXTERNAL, VIEW  ------------------------------

    /// @notice Returns if an oracle was approved for a token
    /// @param token A given token address
    /// @return bool True if an oracle was approved for a token, else - false
    function hasOracle(address token) external view returns (bool) {
        return _tokens.contains(token);
    }

    /// @notice Get all tokens which have approved oracles
    /// @return address[] Array of supported tokens
    function supportedTokens() external view returns (address[] memory) {
        return _tokens.values();
    }

    /// @inheritdoc IOracle
    function price(address token) external view returns (bool success, uint256 priceX96) {
        priceX96 = 0;
        IAggregatorV3 chainlinkOracle = IAggregatorV3(oraclesIndex[token]);
        if (address(chainlinkOracle) == address(0)) {
            return (false, priceX96);
        }
        uint256 oraclePrice;
        (success, oraclePrice) = _queryChainlinkOracle(chainlinkOracle);
        if (!success) {
            return (false, priceX96);
        }

        success = true;
        priceX96 = oraclePrice * priceMultiplier[token];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId) || interfaceId == type(IOracle).interfaceId;
    }

    // -------------------------  EXTERNAL, MUTATING  ------------------------------

    /// @notice Add more chainlink oracles and tokens
    /// @param tokens Array of new tokens
    /// @param oracles Array of new oracles
    function addChainlinkOracles(address[] memory tokens, address[] memory oracles) external {
        _requireAdmin();
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    /// @notice Attempt to send a price query to chainlink oracle
    /// @param oracle Chainlink oracle
    /// @return success Query to chainlink oracle (if oracle.latestRoundData call works correctly => the answer can be received), answer Result of the query
    function _queryChainlinkOracle(IAggregatorV3 oracle) internal view returns (bool success, uint256 answer) {
        try oracle.latestRoundData() returns (uint80, int256 ans, uint256, uint256, uint80) {
            return (true, uint256(ans));
        } catch (bytes memory) {
            return (false, 0);
        }
    }

    // -------------------------  INTERNAL, MUTATING  ------------------------------

    /// @notice Add more chainlink oracles and tokens (internal)
    /// @param tokens Array of new tokens
    /// @param oracles Array of new oracles
    function _addChainlinkOracles(address[] memory tokens, address[] memory oracles) internal {
        if (tokens.length != oracles.length) {
            revert InvalidLength();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address oracle = oracles[i];
            _tokens.add(token);
            oraclesIndex[token] = oracle;

            uint256 decimals = uint256(IERC20Metadata(token).decimals() + IAggregatorV3(oracle).decimals());
            if (DECIMALS > decimals) {
                priceMultiplier[token] = (10**(DECIMALS - decimals)) * Q96;
            } else if (decimals > DECIMALS) {
                priceMultiplier[token] = Q96 / 10**(decimals - DECIMALS);
            }
        }
        emit OraclesAdded(tx.origin, msg.sender, tokens, oracles);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when new Chainlink oracles are added
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokens Tokens added
    /// @param oracles Oracles added for the tokens
    event OraclesAdded(address indexed origin, address indexed sender, address[] tokens, address[] oracles);
}
