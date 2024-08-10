// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import {Script} from "lib/forge-std/src/Script.sol";

import {IAddressResolver} from "script/utils/interfaces/IAddressResolver.sol";

import {Account} from "src/Account.sol";
import {Events} from "src/Events.sol";
import {Settings} from "src/Settings.sol";
import {IAccount} from "src/interfaces/IAccount.sol";

import {
    BNB_PDAO,
    BNB_GELATO,
    BNB_AUTOMATE,
    FUTURES_MARKET_MANAGER,
    BNB_FACTORY,
    BNB_EVENTS,
    BNB_SETTINGS,
    BNB_ADDRESS_RESOLVER,
    PERPS_V2_EXCHANGE_RATE,
    PROXY_ZUSD,
    SYSTEM_STATUS
} from "script/utils/parameters/BNBParameters.sol";
import {
    MUMBAI_DEPLOYER,
    MUMBAI_EVENTS,
    MUMBAI_SETTINGS,
    MUMBAI_FACTORY,
    MUMBAI_EVENTS,
    MUMBAI_GELATO,
    MUMBAI_AUTOMATE,
    MUMBAI_ADDRESS_RESOLVER
} from "script/utils/parameters/MumbaiParameters.sol";

import {
    SEPOLIA_DEPLOYER,
    SEPOLIA_EVENTS,
    SEPOLIA_SETTINGS,
    SEPOLIA_FACTORY,
    SEPOLIA_EVENTS,
    SEPOLIA_GELATO,
    SEPOLIA_AUTOMATE,
    SEPOLIA_ADDRESS_RESOLVER
} from "script/utils/parameters/SepoliaParameters.sol";

/// @title Script to upgrade the Account implementation

/// @dev steps to deploy and verify on BNB:
/// (1) load the variables in the .env file via `source .env`
/// (2) run `forge script script/upgrades/Upgrade.s.sol:UpgradeAccountBNB --rpc-url $ARCHIVE_NODE_URL --broadcast --verify -vvvv`
/// (3) Margin Account Factory owner will need to call `upgradeAccountImplementation` on the Factory with the address of the new Account implementation
contract UpgradeAccountBNB is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        upgrade();

        vm.stopBroadcast();
    }

    function upgrade() public returns (address implementation) {
        IAddressResolver addressResolver =
            IAddressResolver(BNB_ADDRESS_RESOLVER);

        // deploy events
        // address events = address(new Events({_factory: BNB_FACTORY}));

        address marginAsset = addressResolver.getAddress({name: PROXY_ZUSD});
        address perpsV2ExchangeRate =
            addressResolver.getAddress({name: PERPS_V2_EXCHANGE_RATE});
        address futuresMarketManager =
            addressResolver.getAddress({name: FUTURES_MARKET_MANAGER});
        address systemStatus = addressResolver.getAddress({name: SYSTEM_STATUS});

        IAccount.AccountConstructorParams memory params = IAccount
            .AccountConstructorParams({
            factory: BNB_FACTORY,
            events: BNB_EVENTS,
            marginAsset: marginAsset,
            perpsV2ExchangeRate: perpsV2ExchangeRate,
            futuresMarketManager: futuresMarketManager,
            systemStatus: systemStatus,
            gelato: BNB_GELATO,
            automate: BNB_AUTOMATE,
            settings: BNB_SETTINGS
        });

        implementation = address(new Account(params));
    }
}

/// @dev steps to deploy and verify on Mumbai:
/// (1) load the variables in the .env file via `source .env`
/// (2) run `forge script script/upgrades/Upgrade.s.sol:UpgradeAccountMumbai --rpc-url $ARCHIVE_NODE_URL_MUMBAI --broadcast --verify -vvvv`
/// (3) Margin Account Factory owner will need to call `upgradeAccountImplementation` on the Factory with the address of the new Account implementation
contract UpgradeAccountMumbai is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        upgrade();

        vm.stopBroadcast();
    }

    function upgrade() public returns (address implementation) {
        IAddressResolver addressResolver =
            IAddressResolver(MUMBAI_ADDRESS_RESOLVER);

        address marginAsset = addressResolver.getAddress({name: PROXY_ZUSD});
        address perpsV2ExchangeRate =
            addressResolver.getAddress({name: PERPS_V2_EXCHANGE_RATE});
        address futuresMarketManager =
            addressResolver.getAddress({name: FUTURES_MARKET_MANAGER});
        address systemStatus = addressResolver.getAddress({name: SYSTEM_STATUS});

        IAccount.AccountConstructorParams memory params = IAccount
            .AccountConstructorParams({
            factory: MUMBAI_FACTORY,
            events: MUMBAI_EVENTS,
            marginAsset: marginAsset,
            perpsV2ExchangeRate: perpsV2ExchangeRate,
            futuresMarketManager: futuresMarketManager,
            systemStatus: systemStatus,
            gelato: MUMBAI_GELATO,
            automate: MUMBAI_AUTOMATE,
            settings: MUMBAI_SETTINGS
        });

        implementation = address(new Account(params));
    }
}

/// (2) run `forge script script/upgrades/Upgrade.s.sol:UpgradeAccountSepolia --rpc-url $ARCHIVE_NODE_URL_SEPOLIA --broadcast --verify -vvvv`
contract UpgradeAccountSepolia is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        upgrade();

        vm.stopBroadcast();
    }

    function upgrade() public returns (address implementation) {
        IAddressResolver addressResolver =
            IAddressResolver(SEPOLIA_ADDRESS_RESOLVER);

        address marginAsset = addressResolver.getAddress({name: PROXY_ZUSD});
        address perpsV2ExchangeRate =
            addressResolver.getAddress({name: PERPS_V2_EXCHANGE_RATE});
        address futuresMarketManager =
            addressResolver.getAddress({name: FUTURES_MARKET_MANAGER});
        address systemStatus = addressResolver.getAddress({name: SYSTEM_STATUS});

        IAccount.AccountConstructorParams memory params = IAccount
            .AccountConstructorParams({
            factory: SEPOLIA_FACTORY,
            events: SEPOLIA_EVENTS,
            marginAsset: marginAsset,
            perpsV2ExchangeRate: perpsV2ExchangeRate,
            futuresMarketManager: futuresMarketManager,
            systemStatus: systemStatus,
            gelato: SEPOLIA_GELATO,
            automate: SEPOLIA_AUTOMATE,
            settings: SEPOLIA_SETTINGS
        });

        implementation = address(new Account(params));
    }
}
