// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@zkbob/proxy/EIP1967Proxy.sol";
import "../interfaces/oracles/IOracle.sol";
import "../oracles/ChainlinkOracle.sol";
import "../Vault.sol";
import "../VaultRegistry.sol";
import "./ConfigContract.sol";

abstract contract AbstractDeployment is ConfigContract {
    function _deployOracle(
        address positionManager_,
        IOracle oracle_,
        uint256 maxPriceRatioDeviation_
    ) internal virtual returns (INFTOracle oracle);

    function _getPool(
        address token0,
        address token1,
        uint256 fee
    ) internal view virtual returns (address pool);

    function governancePools() public view returns (address[] memory pools, uint256[] memory liquidationThresholds) {
        uint256 poolsCount = poolsParams.length;
        pools = new address[](poolsCount);
        liquidationThresholds = new uint256[](poolsCount);

        for (uint256 i = 0; i < poolsCount; ++i) {
            pools[i] = _getPool(poolsParams[i].token0, poolsParams[i].token1, poolsParams[i].fee);
            liquidationThresholds[i] = poolsParams[i].liquidationThreshold;
        }
    }

    function run() external {
        _parseConfigs();
        vm.startBroadcast();
        string memory deploymentJson;

        (address[] memory oracleTokens, address[] memory oracles, uint48[] memory heartbeats) = oracleParams();

        ChainlinkOracle oracle = new ChainlinkOracle(oracleTokens, oracles, heartbeats, baseParams.validPeriod);
        console2.log("Chainlink Oracle", address(oracle));
        vm.serializeAddress(deploymentJson, "ChainlinkOracle", address(oracle));

        INFTOracle nftOracle = _deployOracle(
            baseParams.positionManager,
            IOracle(address(oracle)),
            baseParams.maxPriceRatioDeviation
        );
        console2.log("NFT Oracle", address(nftOracle));
        vm.serializeAddress(deploymentJson, "NFTOracle", address(nftOracle));

        Vault vault = new Vault(
            INonfungiblePositionManager(baseParams.positionManager),
            INFTOracle(address(nftOracle)),
            baseParams.treasury,
            baseParams.bobToken
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            baseParams.stabilisationFee,
            type(uint256).max
        );
        EIP1967Proxy vaultProxy = new EIP1967Proxy(msg.sender, address(vault), initData);
        vault = Vault(address(vaultProxy));

        setupGovernance(ICDP(address(vault)));

        console2.log("Vault", address(vault));
        vm.serializeAddress(deploymentJson, "Vault", address(vault));

        VaultRegistry vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "");

        EIP1967Proxy vaultRegistryProxy = new EIP1967Proxy(msg.sender, address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        console2.log("VaultRegistry", address(vaultRegistry));
        string memory finalDeploymentJson = vm.serializeAddress(
            deploymentJson,
            "VaultRegistry",
            address(vaultRegistry)
        );
        vm.stopBroadcast();
        vm.writeJson(
            finalDeploymentJson,
            string.concat(vm.projectRoot(), "/deployments/", chain, "_", amm, "_deployment.json")
        );
    }

    function setupGovernance(ICDP cdp) public {
        (address[] memory pools, uint256[] memory liquidationThresholds) = governancePools();

        cdp.changeLiquidationFee(uint32(baseParams.liquidationFeeD));
        cdp.changeLiquidationPremium(uint32(baseParams.liquidationPremiumD));
        cdp.changeMinSingleNftCollateral(baseParams.minSingleNftCollateral);
        cdp.changeMaxDebtPerVault(baseParams.maxDebtPerVault);
        cdp.changeMaxNftsPerVault(uint8(baseParams.maxNftsPerVault));

        for (uint256 i = 0; i < pools.length; ++i) {
            cdp.setWhitelistedPool(pools[i]);
            cdp.setLiquidationThreshold(pools[i], liquidationThresholds[i]);
        }
    }
}

abstract contract AbstractMainnetDeployment is AbstractDeployment {
    constructor() {
        chain = "mainnet";
    }
}

abstract contract AbstractPolygonDeployment is AbstractDeployment {
    constructor() {
        chain = "polygon";
    }
}
