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

    mapping(address => address) public oraclesIndex;
    mapping(address => uint256) public priceMultiplier;
    EnumerableSet.AddressSet private _tokens;

    constructor(
        address[] memory tokens,
        address[] memory oracles,
        address admin
    ) DefaultAccessControl(admin) {
        _addChainlinkOracles(tokens, oracles);
    }

    // -------------------------  EXTERNAL, VIEW  ------------------------------

    function hasOracle(address token) external view returns (bool) {
        return _tokens.contains(token);
    }

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

            uint256 decimals = uint256(IERC20Metadata(token).decimals() + IAggregatorV3(oracle).decimals());
            uint256 multiplierNumerator = 1;
            uint256 multiplierDenominator = 1;
            if (DECIMALS > decimals) {
                multiplierNumerator *= 10**(DECIMALS - decimals);
            } else if (decimals > DECIMALS) {
                multiplierDenominator *= 10**(decimals - DECIMALS);
            }
            priceMultiplier[token] = FullMath.mulDiv(multiplierNumerator, Q96, multiplierDenominator);
        }
        emit OraclesAdded(tx.origin, msg.sender, tokens, oracles);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when new Chainlink oracle is added
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokens Tokens added
    /// @param oracles Oracles added for the tokens
    event OraclesAdded(address indexed origin, address indexed sender, address[] tokens, address[] oracles);
}
