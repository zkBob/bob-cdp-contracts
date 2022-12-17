// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../interfaces/oracles/IOracle.sol";
import "../interfaces/IProtocolGovernance.sol";
import "../interfaces/IMUSD.sol";
import "../oracles/ChainlinkOracle.sol";
import "../Vault.sol";
import "../interfaces/external/univ3/IUniswapV3Factory.sol";
import "../interfaces/external/univ3/IUniswapV3Pool.sol";
import "../interfaces/external/univ3/INonfungiblePositionManager.sol";
import "../ProtocolGovernance.sol";
import "../MUSD.sol";
import "../proxy/EIP1967Proxy.sol";

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

    function oracleParams() public pure virtual returns (address[] memory oracleTokens, address[] memory oracles);

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
        (address[] memory oracleTokens, address[] memory oracles) = oracleParams();

        ChainlinkOracle oracle = new ChainlinkOracle(oracleTokens, oracles, msg.sender);
        console2.log("Oracle", address(oracle));

        ProtocolGovernance protocolGovernance = new ProtocolGovernance(msg.sender, type(uint256).max);
        console2.log("ProtocolGovernance", address(protocolGovernance));

        setupGovernance(IProtocolGovernance(protocolGovernance), factory);

        Vault vault = new Vault(
            INonfungiblePositionManager(positionManager),
            IUniswapV3Factory(factory),
            IProtocolGovernance(protocolGovernance),
            treasury
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            IOracle(oracle),
            stabilisationFee
        );
        EIP1967Proxy vaultProxy = new EIP1967Proxy(msg.sender, address(vault), initData);
        vault = Vault(address(vaultProxy));

        console2.log("Vault", address(vault));

        MUSD token = new MUSD("Mellow USD", "MUSD", address(vault));
        vault.setToken(IMUSD(address(token)));
        console2.log("Token", address(token));

        vm.stopBroadcast();
    }

    function setupGovernance(IProtocolGovernance governance, address factory) public {
        (
            uint256 minSingleNftCollateral,
            uint256 maxDebtPerVault,
            uint32 liquidationFeeD,
            uint32 liquidationPremiumD,
            uint8 maxNftsPerVault,
            address[] memory pools,
            uint256[] memory liquidationThresholds
        ) = governanceParams(factory);

        governance.changeLiquidationFee(liquidationFeeD);
        governance.changeLiquidationPremium(liquidationPremiumD);
        governance.changeMinSingleNftCollateral(minSingleNftCollateral);
        governance.changeMaxDebtPerVault(maxDebtPerVault);
        governance.changeMaxNftsPerVault(maxNftsPerVault);

        for (uint256 i = 0; i < pools.length; ++i) {
            governance.setWhitelistedPool(pools[i]);
            governance.setLiquidationThreshold(pools[i], liquidationThresholds[i]);
        }
    }
}
