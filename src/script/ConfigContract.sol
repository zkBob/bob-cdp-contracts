// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract ConfigContract is Script {
    using stdJson for string;

    string chain;
    string amm;

    string deploymentJson = "deployment";
    string deploymentJsonSerialized = "{}";

    struct Params {
        address bobToken;
        address factory;
        uint256 liquidationFeeD;
        uint256 liquidationPremiumD;
        uint256 maxDebtPerVault;
        uint256 maxNftsPerVault;
        uint256 maxPriceRatioDeviation;
        uint256 minSingleNftCollateral;
        address minter;
        address owner;
        PoolParams[] pools;
        address positionManager;
        uint256 stabilisationFee;
        TokenParams[] tokens;
        address treasury;
        uint256 validPeriod;
    }

    struct TokenParams {
        address chainlinkOracle;
        uint256 chainlinkOracleHeartbeat;
        address tokenAddress;
    }

    struct PoolParams {
        uint32 borrowThresholdD;
        uint256 fee;
        uint32 liquidationThresholdD;
        uint24 minWidth;
        address token0;
        address token1;
    }

    function _parseConfigs() internal returns (Params memory res) {
        string memory root = vm.projectRoot();
        string memory paramsPath = string.concat(root, "/src/script/configs/", chain, "/", amm, ".json");
        string memory rawJson = vm.readFile(paramsPath);
        bytes memory abiEncodedJson = vm.parseJson(rawJson);
        res = abi.decode(abiEncodedJson, (Params));
        require(keccak256(abiEncodedJson) == keccak256(abi.encode(res)), "Invalid config");
    }

    function recordDeployedContract(string memory contractName, address contractAddress) internal {
        console2.log(contractName, contractAddress);
        deploymentJsonSerialized = deploymentJson.serialize(contractName, contractAddress);
    }

    function writeDeployment(string memory path) internal {
        deploymentJsonSerialized.write(path);
    }
}
