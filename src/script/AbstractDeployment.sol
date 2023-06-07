// SPDX-License-Identifier: CC0-1.0

pragma solidity ^0.8.0;

import "@zkbob/proxy/EIP1967Proxy.sol";
import {FlashMinter} from "@zkbob/minters/FlashMinter.sol";
import {DebtMinter} from "@zkbob/minters/DebtMinter.sol";
import {SurplusMinter} from "@zkbob/minters/SurplusMinter.sol";
import "../interfaces/oracles/IOracle.sol";
import "../oracles/ChainlinkOracle.sol";
import "../Vault.sol";
import "../VaultRegistry.sol";
import "./ConfigContract.sol";
import "../oracles/ConstPriceChainlinkOracle.sol";

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

        oracles[0] = address(new ConstPriceChainlinkOracle(1e8, 8));
        recordDeployedContract("BobPriceOracle", address(oracles[0]));

        IOracle oracle = new ChainlinkOracle(oracleTokens, oracles, heartbeats, params.validPeriod);
        recordDeployedContract("ChainlinkOracle", address(oracle));

        INFTOracle nftOracle = _deployOracle(params.positionManager, oracle, params.maxPriceRatioDeviation);
        recordDeployedContract("NFTOracle", address(nftOracle));

        VaultRegistry vaultRegistry = new VaultRegistry("BOB CDP NFT", "BOB-CDP", "");
        EIP1967Proxy vaultRegistryProxy = new EIP1967Proxy(msg.sender, address(vaultRegistry), "");
        vaultRegistry = VaultRegistry(address(vaultRegistryProxy));
        recordDeployedContract("VaultRegistry", address(vaultRegistry));

        SurplusMinter surplusMinter = new SurplusMinter(address(params.bobToken));
        recordDeployedContract("SurplusMinter", address(surplusMinter));
        FlashMinter flashMinter = new FlashMinter({
            _token: address(params.bobToken),
            _limit: 200_000 ether,
            _treasury: address(surplusMinter),
            _fee: 0,
            _maxFee: 0
        });
        recordDeployedContract("FlashMinter", address(flashMinter));
        DebtMinter debtMinter = new DebtMinter({
            _token: address(params.bobToken),
            _maxDebtLimit: 500_000 ether,
            _minDebtLimit: 500_000 ether,
            _raiseDelay: 12 hours,
            _raise: 0,
            _treasury: address(surplusMinter)
        });
        recordDeployedContract("DebtMinter", address(debtMinter));

        Vault vault = new Vault(
            INonfungiblePositionManager(params.positionManager),
            nftOracle,
            address(surplusMinter),
            params.bobToken,
            address(debtMinter),
            address(vaultRegistry)
        );

        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            msg.sender,
            params.stabilisationFee,
            type(uint256).max
        );
        {
            EIP1967Proxy vaultProxy = new EIP1967Proxy(params.owner, address(vault), initData);
            vault = Vault(address(vaultProxy));
        }
        recordDeployedContract("Vault", address(vault));

        setupGovernance(params, ICDP(address(vault)));

        debtMinter.setMinter(address(vault), true);
        surplusMinter.setMinter(address(vault), true);
        vaultRegistry.setMinter(address(vault), true);

        {
            address zkBobGovernance = EIP1967Proxy(payable(params.bobToken)).admin();
            debtMinter.transferOwnership(zkBobGovernance);
            surplusMinter.transferOwnership(zkBobGovernance);
        }

        // vault.makePublic();
        // vault.addLiquidatorsToAllowlist(...);

        flashMinter.transferOwnership(params.owner);

        Ownable(address(oracle)).transferOwnership(params.owner);
        Ownable(address(nftOracle)).transferOwnership(params.owner);

        vaultRegistryProxy.setAdmin(params.owner);
        vault.grantRole(vault.ADMIN_ROLE(), params.owner);
        vault.renounceRole(vault.ADMIN_ROLE(), msg.sender);
        // vault.renounceRole(vault.OPERATOR(), msg.sender);

        vm.stopBroadcast();
        writeDeployment(string.concat(vm.projectRoot(), "/deployments/", chain, "_", amm, "_deployment.json"));
    }

    function setupGovernance(Params memory params, ICDP cdp) public {
        cdp.changeLiquidationFee(uint32(params.liquidationFeeD));
        cdp.changeLiquidationPremium(uint32(params.liquidationPremiumD));
        cdp.changeMinSingleNftCollateral(100 ether); // https://github.com/foundry-rs/foundry/issues/5038
        cdp.changeMaxDebtPerVault(100_000 ether);
        cdp.changeMaxNftsPerVault(uint8(params.maxNftsPerVault));

        for (uint256 i = 0; i < params.pools.length; ++i) {
            PoolParams memory pool = params.pools[i];
            address poolAddr = _getPool(params.factory, pool.token0, pool.token1, pool.fee);
            cdp.setPoolParams(
                poolAddr,
                ICDP.PoolParams(pool.liquidationThresholdD, pool.borrowThresholdD, pool.minWidth)
            );
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
