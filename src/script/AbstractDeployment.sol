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

    function _getPool(address token0, address token1) internal view virtual returns (address pool);

    function governancePools() public view returns (address[] memory pools, uint256[] memory liquidationThresholds) {
        pools = new address[](3);

        pools[0] = _getPool(baseParams.wbtc, baseParams.usdc);
        pools[1] = _getPool(baseParams.weth, baseParams.usdc);
        pools[2] = _getPool(baseParams.wbtc, baseParams.weth);

        liquidationThresholds = new uint256[](3);

        liquidationThresholds[0] = governanceParams.wbtcUsdcPoolLiquidationThreshold;
        liquidationThresholds[1] = governanceParams.wethUsdcPoolLiquidationThreshold;
        liquidationThresholds[2] = governanceParams.wbtcWethPoolLiquidationThreshold;
    }

    function run() external {
        _parseConfigs();
        vm.startBroadcast();

        (address[] memory oracleTokens, address[] memory oracles, uint48[] memory heartbeats) = oracleParams();

        ChainlinkOracle oracle = new ChainlinkOracle(oracleTokens, oracles, heartbeats, 3600);
        console2.log("Chainlink Oracle", address(oracle));

        INFTOracle nftOracle = _deployOracle(ammParams.positionManager, IOracle(address(oracle)), 10**16);
        console2.log("NFT Oracle", address(oracle));

        Vault vault = new Vault(
            INonfungiblePositionManager(ammParams.positionManager),
            INFTOracle(address(nftOracle)),
            baseParams.treasury,
            baseParams.bobToken
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            governanceParams.stabilisationFee,
            type(uint256).max
        );
        EIP1967Proxy vaultProxy = new EIP1967Proxy(msg.sender, address(vault), initData);
        vault = Vault(address(vaultProxy));

        setupGovernance(ICDP(address(vault)));

        console2.log("Vault", address(vault));

        VaultRegistry vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "");

        EIP1967Proxy vaultRegistryProxy = new EIP1967Proxy(msg.sender, address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        console2.log("VaultRegistry", address(vaultRegistry));

        vm.stopBroadcast();
    }

    function setupGovernance(ICDP cdp) public {
        (address[] memory pools, uint256[] memory liquidationThresholds) = governancePools();

        cdp.changeLiquidationFee(uint32(governanceParams.liquidationFeeD));
        cdp.changeLiquidationPremium(uint32(governanceParams.liquidationPremiumD));
        cdp.changeMinSingleNftCollateral(governanceParams.minSingleNftCollateral);
        cdp.changeMaxDebtPerVault(governanceParams.maxDebtPerVault);
        cdp.changeMaxNftsPerVault(uint8(governanceParams.maxNftsPerVault));

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
