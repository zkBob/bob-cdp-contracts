// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/external/chainlink/IAggregatorV3.sol";
import "../interfaces/oracles/IOracle.sol";
import "../libraries/external/FullMath.sol";
import "../proxy/EIP1967Admin.sol";

/// @notice Contract for getting chainlink data
contract ChainlinkOracle is IOracle, Ownable {
    /// @notice Thrown when tokens.length != oracles.length
    error InvalidLength();

    /// @notice Thrown when price feed doesn't work by some reason
    error InvalidOracle();

    /// @notice Price update error
    error PriceUpdateFailed();

    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DECIMALS = 18;
    uint256 public constant Q96 = 2**96;

    struct PriceData {
        IAggregatorV3 feed;
        uint48 heartbeat;
        uint48 fallbackUpdatedAt;
        uint256 fallbackPriceX96;
        uint256 priceMultiplier;
    }

    /// @notice Mapping, returning underlying prices for each token
    mapping(address => PriceData) public pricesInfo;

    /// @notice Address set, containing tokens, supported by the oracles
    EnumerableSet.AddressSet private _tokens;

    /// @notice Valid period of underlying prices (in seconds)
    uint256 public validPeriod;

    /// @notice Creates a new contract
    /// @param tokens Initial supported tokens
    /// @param oracles Initial approved Chainlink oracles
    /// @param heartbeats Initial heartbeats for chainlink oracles
    /// @param validPeriod_ Initial valid period of underlying prices (in seconds)
    constructor(
        address[] memory tokens,
        address[] memory oracles,
        uint48[] memory heartbeats,
        uint256 validPeriod_
    ) {
        validPeriod = validPeriod_;
        _addChainlinkOracles(tokens, oracles, heartbeats);
    }

    // -------------------------  EXTERNAL, VIEW  ------------------------------

    /// @inheritdoc IOracle
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
        PriceData storage priceData = pricesInfo[token];
        (IAggregatorV3 feed, uint48 heartbeat, uint48 fallbackUpdatedAt) = (
            priceData.feed,
            priceData.heartbeat,
            priceData.fallbackUpdatedAt
        );
        uint256 oraclePrice;
        uint256 updatedAt;
        if (address(priceData.feed) == address(0)) {
            return (false, 0);
        }
        (success, oraclePrice, updatedAt) = _queryChainlinkOracle(feed);
        if (!success || updatedAt + heartbeat < block.timestamp) {
            if (block.timestamp <= fallbackUpdatedAt + validPeriod) {
                return (true, priceData.fallbackPriceX96);
            } else {
                return (false, 0);
            }
        }

        success = true;
        priceX96 = oraclePrice * priceData.priceMultiplier;
    }

    // -------------------------  EXTERNAL, MUTATING  ------------------------------

    /// @notice Add more chainlink oracles and tokens
    /// @param tokens Array of new tokens
    /// @param oracles Array of new oracles
    /// @param heartbeats Array of heartbeats for oracles
    function addChainlinkOracles(
        address[] memory tokens,
        address[] memory oracles,
        uint48[] memory heartbeats
    ) external onlyOwner {
        _addChainlinkOracles(tokens, oracles, heartbeats);
    }

    /// @notice Set new valid period
    /// @param validPeriod_ New valid period
    function setValidPeriod(uint256 validPeriod_) external onlyOwner {
        validPeriod = validPeriod_;
        emit ValidPeriodUpdated(tx.origin, msg.sender, validPeriod_);
    }

    /// @notice Set new underlying fallbackPriceX96 for specific token
    /// @param token Address of the token
    /// @param fallbackPriceX96 Value of price multiplied by 2**96
    /// @param fallbackUpdatedAt Timestamp of the price
    function setUnderlyingPriceX96(
        address token,
        uint256 fallbackPriceX96,
        uint48 fallbackUpdatedAt
    ) external onlyOwner {
        if (fallbackUpdatedAt >= block.timestamp) {
            fallbackUpdatedAt = uint48(block.timestamp);
        } else if (fallbackUpdatedAt + validPeriod < block.timestamp) {
            revert PriceUpdateFailed();
        }

        PriceData storage priceData = pricesInfo[token];

        priceData.fallbackUpdatedAt = fallbackUpdatedAt;
        priceData.fallbackPriceX96 = fallbackPriceX96;

        emit PricePosted(tx.origin, msg.sender, token, fallbackPriceX96, fallbackUpdatedAt);
    }

    // -------------------------  INTERNAL, VIEW  ------------------------------

    /// @notice Attempt to send a price query to chainlink oracle
    /// @param oracle Chainlink oracle
    /// @return success Query to chainlink oracle (if oracle.latestRoundData call works correctly => the answer can be received), answer Result of the query
    function _queryChainlinkOracle(IAggregatorV3 oracle)
        internal
        view
        returns (
            bool success,
            uint256 answer,
            uint256 fallbackUpdatedAt
        )
    {
        try oracle.latestRoundData() returns (uint80, int256 ans, uint256, uint256 fallbackUpdatedAt_, uint80) {
            if (ans <= 0) {
                return (false, 0, 0);
            }
            return (true, uint256(ans), fallbackUpdatedAt_);
        } catch (bytes memory) {
            return (false, 0, 0);
        }
    }

    // -------------------------  INTERNAL, MUTATING  ------------------------------

    /// @notice Add more chainlink oracles and tokens (internal)
    /// @param tokens Array of new tokens
    /// @param oracles Array of new oracles
    /// @param heartbeats Array of heartbeats for oracles
    function _addChainlinkOracles(
        address[] memory tokens,
        address[] memory oracles,
        uint48[] memory heartbeats
    ) internal {
        if (tokens.length != oracles.length || oracles.length != heartbeats.length) {
            revert InvalidLength();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address oracle = oracles[i];
            uint48 heartbeat = heartbeats[i];

            IAggregatorV3 chainlinkOracle = IAggregatorV3(oracle);
            (bool flag, , ) = _queryChainlinkOracle(chainlinkOracle);

            if (!flag) {
                revert InvalidOracle(); // hence a token for this 'oracle' can not be added
            }

            _tokens.add(token);

            uint256 decimals = uint256(IERC20Metadata(token).decimals() + IAggregatorV3(oracle).decimals());
            uint256 priceMultiplier;
            if (DECIMALS > decimals) {
                priceMultiplier = (10**(DECIMALS - decimals)) * Q96;
            } else {
                priceMultiplier = Q96 / 10**(decimals - DECIMALS);
            }

            pricesInfo[token] = PriceData({
                feed: chainlinkOracle,
                heartbeat: heartbeat,
                fallbackUpdatedAt: 0,
                fallbackPriceX96: 0,
                priceMultiplier: priceMultiplier
            });
        }
        emit OraclesAdded(tx.origin, msg.sender, tokens, oracles, heartbeats);
    }

    // --------------------------  EVENTS  --------------------------

    /// @notice Emitted when new Chainlink oracles are added
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param tokens Tokens added
    /// @param oracles Oracles added for the tokens
    /// @param heartbeats Array of heartbeats for oracles
    event OraclesAdded(
        address indexed origin,
        address indexed sender,
        address[] tokens,
        address[] oracles,
        uint48[] heartbeats
    );

    /// @notice Emitted when underlying price of the token updates
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param token Address of the token
    /// @param newPriceX96 New underlying price multiplied by 2**96
    /// @param fallbackUpdatedAt Timestamp of underlying price updating
    event PricePosted(
        address indexed origin,
        address indexed sender,
        address token,
        uint256 newPriceX96,
        uint48 fallbackUpdatedAt
    );

    /// @notice Emitted when validPeriod updates
    /// @param origin Origin of the transaction (tx.origin)
    /// @param sender Sender of the call (msg.sender)
    /// @param validPeriod Current valid period
    event ValidPeriodUpdated(address indexed origin, address indexed sender, uint256 validPeriod);
}
