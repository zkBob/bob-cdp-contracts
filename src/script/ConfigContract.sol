// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract ConfigContract is Script {
    using stdJson for string;

    string chain;
    string amm;

    struct BaseParams {
        address wbtc;
        address weth;
        address usdc;
        address chainlinkBtc;
        address chainlinkUsdc;
        address chainlinkEth;
        uint256 chainlinkBtcHeartbeat;
        uint256 chainlinkUsdcHeartbeat;
        uint256 chainlinkEthHeartbeat;
        address bobToken;
        address treasury;
    }

    struct GovernanceParams {
        uint256 stabilisationFee;
        uint256 liquidationFeeD;
        uint256 liquidationPremiumD;
        uint256 minSingleNftCollateral;
        uint256 maxDebtPerVault;
        uint256 maxNftsPerVault;
        uint256 wbtcUsdcPoolLiquidationThreshold;
        uint256 wethUsdcPoolLiquidationThreshold;
        uint256 wbtcWethPoolLiquidationThreshold;
    }

    struct AmmParams {
        address positionManager;
        address factory;
    }

    BaseParams public baseParams;
    AmmParams public ammParams;
    GovernanceParams public governanceParams;

    function _parseConfigs() internal {
        string memory root = vm.projectRoot();
        string memory baseParamsPath = string.concat(root, "/src/script/configs/", chain, "/base.json");
        string memory ammParamsPath = string.concat(root, "/src/script/configs/", chain, "/", amm, ".json");
        string memory governanceParamsPath = string.concat(root, "/src/script/configs/", chain, "/", amm, ".json");
        baseParams = abi.decode(vm.parseJson(vm.readFile(baseParamsPath)), (BaseParams));
        ammParams = abi.decode(vm.parseJson(vm.readFile(ammParamsPath)), (AmmParams));
        governanceParams = abi.decode(vm.parseJson(vm.readFile(governanceParamsPath)), (GovernanceParams));
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
        oracleTokens = new address[](3);

        oracleTokens[0] = baseParams.wbtc;
        oracleTokens[1] = baseParams.usdc;
        oracleTokens[2] = baseParams.weth;

        oracles = new address[](3);

        oracles[0] = baseParams.chainlinkBtc;
        oracles[1] = baseParams.chainlinkUsdc;
        oracles[2] = baseParams.chainlinkEth;

        heartbeats = new uint48[](3);

        heartbeats[0] = uint48(baseParams.chainlinkBtcHeartbeat);
        heartbeats[1] = uint48(baseParams.chainlinkUsdcHeartbeat);
        heartbeats[2] = uint48(baseParams.chainlinkEthHeartbeat);
    }
}
