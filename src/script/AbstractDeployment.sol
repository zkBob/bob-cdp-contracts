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
        address factory,
        address token0,
        address token1,
        uint256 fee
    ) internal view virtual returns (address pool);

    function oracleParams(Params memory params)
        public
        view
        returns (
            address[] memory oracleTokens,
            address[] memory oracles,
            uint48[] memory heartbeats
        )
    {
        uint256 tokensCount = params.tokens.length;
        oracleTokens = new address[](tokensCount);
        oracles = new address[](tokensCount);
        heartbeats = new uint48[](tokensCount);

        for (uint256 i = 0; i < tokensCount; ++i) {
            oracleTokens[i] = params.tokens[i].tokenAddress;
            oracles[i] = params.tokens[i].chainlinkOracle;
            heartbeats[i] = uint48(params.tokens[i].chainlinkOracleHeartbeat);
        }
    }

    function run() external {
        Params memory params = _parseConfigs();
        vm.startBroadcast();

        (address[] memory oracleTokens, address[] memory oracles, uint48[] memory heartbeats) = oracleParams(params);

        IOracle oracle = new ChainlinkOracle(oracleTokens, oracles, heartbeats, params.validPeriod);
        recordDeployedContract("ChainlinkOracle", address(oracle));

        INFTOracle nftOracle = _deployOracle(params.positionManager, oracle, params.maxPriceRatioDeviation);
        recordDeployedContract("NFTOracle", address(nftOracle));

        VaultRegistry vaultRegistry = new VaultRegistry("BOB Vault Token", "BVT", "");
        EIP1967Proxy vaultRegistryProxy = new EIP1967Proxy(msg.sender, address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));
        recordDeployedContract("VaultRegistry", address(vaultRegistry));

        Vault vault = new Vault(
            INonfungiblePositionManager(params.positionManager),
            nftOracle,
            params.treasury,
            params.bobToken,
            params.minter,
            address(vaultRegistry)
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            params.stabilisationFee,
            type(uint256).max
        );
        EIP1967Proxy vaultProxy = new EIP1967Proxy(msg.sender, address(vault), initData);
        vault = Vault(address(vaultProxy));
        recordDeployedContract("Vault", address(vault));

        setupGovernance(params, ICDP(address(vault)));

        vaultRegistry.setMinter(address(vault), true);

        vm.stopBroadcast();
        writeDeployment(string.concat(vm.projectRoot(), "/deployments/", chain, "_", amm, "_deployment.json"));
    }

    function setupGovernance(Params memory params, ICDP cdp) public {
        cdp.changeLiquidationFee(uint32(params.liquidationFeeD));
        cdp.changeLiquidationPremium(uint32(params.liquidationPremiumD));
        cdp.changeMinSingleNftCollateral(params.minSingleNftCollateral);
        cdp.changeMaxDebtPerVault(params.maxDebtPerVault);
        cdp.changeMaxNftsPerVault(uint8(params.maxNftsPerVault));

        for (uint256 i = 0; i < params.pools.length; ++i) {
            PoolParams memory pool = params.pools[i];
            address poolAddr = _getPool(params.factory, pool.token0, pool.token1, pool.fee);
            cdp.setWhitelistedPool(poolAddr);
            cdp.setLiquidationThreshold(poolAddr, pool.liquidationThreshold);
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

abstract contract AbstractGoerliDeployment is AbstractDeployment {
    constructor() {
        chain = "goerli";
    }
}
