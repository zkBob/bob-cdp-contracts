// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "@zkbob/proxy/EIP1967Proxy.sol";
import "../interfaces/oracles/IOracle.sol";
import "../oracles/ChainlinkOracle.sol";
import "../oracles/UniV3Oracle.sol";
import "../Vault.sol";
import "../VaultRegistry.sol";

abstract contract AbstractDeployment is Script {
    function tokens()
        public
        pure
        virtual
        returns (
            address wbtc,
            address weth,
            address usdc
        );

    function oracleParams()
        public
        pure
        virtual
        returns (
            address[] memory oracleTokens,
            address[] memory oracles,
            uint48[] memory heartbeats
        );

    function vaultParams()
        public
        pure
        virtual
        returns (
            address positionManager,
            address factory,
            address treasury,
            uint256 stabilisationFee
        );

    function targetToken() public pure virtual returns (address token);

    function governanceParams(address factory)
        public
        view
        returns (
            uint256 minSingleNftCollateral,
            uint256 maxDebtPerVault,
            uint32 liquidationFeeD,
            uint32 liquidationPremiumD,
            uint8 maxNftsPerVault,
            address[] memory pools,
            uint256[] memory liquidationThresholds
        )
    {
        liquidationFeeD = 3 * 10**7;
        liquidationPremiumD = 3 * 10**7;
        minSingleNftCollateral = 10**17;
        maxDebtPerVault = type(uint256).max;
        maxNftsPerVault = 20;

        pools = new address[](3);

        (address wbtc, address weth, address usdc) = tokens();

        pools[0] = IUniswapV3Factory(factory).getPool(wbtc, usdc, 3000);
        pools[1] = IUniswapV3Factory(factory).getPool(weth, usdc, 3000);
        pools[2] = IUniswapV3Factory(factory).getPool(wbtc, weth, 3000);

        liquidationThresholds = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            liquidationThresholds[i] = 6e8;
        }
    }

    function run() external {
        vm.startBroadcast();

        (address positionManager, address factory, address treasury, uint256 stabilisationFee) = vaultParams();
        (address[] memory oracleTokens, address[] memory oracles, uint48[] memory heartbeats) = oracleParams();
        address token = targetToken();

        ChainlinkOracle oracle = new ChainlinkOracle(oracleTokens, oracles, heartbeats, 3600);
        console2.log("Chainlink Oracle", address(oracle));

        UniV3Oracle nftOracle = new UniV3Oracle(
            INonfungiblePositionManager(positionManager),
            IOracle(address(oracle)),
            10**17
        );
        console2.log("UniV3 Oracle", address(oracle));

        Vault vault = new Vault(
            INonfungiblePositionManager(positionManager),
            INFTOracle(address(nftOracle)),
            treasury,
            token
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            stabilisationFee,
            type(uint256).max
        );
        EIP1967Proxy vaultProxy = new EIP1967Proxy(msg.sender, address(vault), initData);
        vault = Vault(address(vaultProxy));

        setupGovernance(ICDP(address(vault)), factory);

        console2.log("Vault", address(vault));

        VaultRegistry vaultRegistry = new VaultRegistry(ICDP(address(vault)), "BOB Vault Token", "BVT", "");

        EIP1967Proxy vaultRegistryProxy = new EIP1967Proxy(msg.sender, address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));

        vault.setVaultRegistry(IVaultRegistry(address(vaultRegistry)));

        console2.log("VaultRegistry", address(vaultRegistry));

        vm.stopBroadcast();
    }

    function setupGovernance(ICDP cdp, address factory) public {
        (
            uint256 minSingleNftCollateral,
            uint256 maxDebtPerVault,
            uint32 liquidationFeeD,
            uint32 liquidationPremiumD,
            uint8 maxNftsPerVault,
            address[] memory pools,
            uint256[] memory liquidationThresholds
        ) = governanceParams(factory);

        cdp.changeLiquidationFee(liquidationFeeD);
        cdp.changeLiquidationPremium(liquidationPremiumD);
        cdp.changeMinSingleNftCollateral(minSingleNftCollateral);
        cdp.changeMaxDebtPerVault(maxDebtPerVault);
        cdp.changeMaxNftsPerVault(maxNftsPerVault);

        for (uint256 i = 0; i < pools.length; ++i) {
            cdp.setWhitelistedPool(pools[i]);
            cdp.setLiquidationThreshold(pools[i], liquidationThresholds[i]);
        }
    }
}
