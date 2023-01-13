// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract ConfigContract is Script {
    using stdJson for string;

    string chain;
    string amm;

    struct BaseParams {
        address bobToken;
        address factory;
        uint256 liquidationFeeD;
        uint256 liquidationPremiumD;
        uint256 maxDebtPerVault;
        uint256 maxPriceRatioDeviation;
        uint256 minSingleNftCollateral;
        uint256 maxNftsPerVault;
        address positionManager;
        uint256 stabilisationFee;
        address treasury;
        uint256 validPeriod;
    }

    struct TokenParams {
        address chainlinkOracle;
        uint256 chainlinkOracleHeartbeat;
        address tokenAddress;
    }

    struct PoolParams {
        uint256 fee;
        uint256 liquidationThreshold;
        address token0;
        address token1;
    }

    BaseParams public baseParams;
    TokenParams[] public tokensParams;
    PoolParams[] public poolsParams;

    function _parseConfigs() internal {
        string memory root = vm.projectRoot();
        string memory paramsPath = string.concat(root, "/src/script/configs/", chain, "/", amm, ".json");
        string memory rawJson = vm.readFile(paramsPath);
        baseParams = abi.decode(vm.parseJson(rawJson, ".baseParams"), (BaseParams));
        TokenParams[] memory tokensParams_ = abi.decode(vm.parseJson(rawJson, ".tokens"), (TokenParams[]));
        for (uint256 i = 0; i < tokensParams_.length; ++i) {
            tokensParams.push(tokensParams_[i]);
        }
        PoolParams[] memory poolsParams_ = abi.decode(vm.parseJson(rawJson, ".pools"), (PoolParams[]));
        for (uint256 i = 0; i < poolsParams_.length; ++i) {
            poolsParams.push(poolsParams_[i]);
        }
    }

    function oracleParams()
        public
        view
        returns (
            address[] memory oracleTokens,
            address[] memory oracles,
            uint48[] memory heartbeats
        )
    {
        uint256 tokensCount = tokensParams.length;
        oracleTokens = new address[](tokensCount);
        oracles = new address[](tokensCount);
        heartbeats = new uint48[](tokensCount);

        for (uint256 i = 0; i < tokensCount; ++i) {
            oracleTokens[i] = tokensParams[i].tokenAddress;
            oracles[i] = tokensParams[i].chainlinkOracle;
            heartbeats[i] = uint48(tokensParams[i].chainlinkOracleHeartbeat);
        }
    }
}
