// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import {Script} from "lib/forge-std/src/Script.sol";

import {IAddressResolver} from "script/utils/interfaces/IAddressResolver.sol";

import {Account} from "src/Account.sol";
import {Events} from "src/Events.sol";
import {Factory} from "src/Factory.sol";
import {IAccount} from "src/interfaces/IAccount.sol";
import {Settings} from "src/Settings.sol";

import {
    BNB_DEPLOYER,
    BNB_PDAO,
    BNB_ADDRESS_RESOLVER,
    BNB_GELATO,
    BNB_AUTOMATE,
    PROXY_ZUSD,
    PERPS_V2_EXCHANGE_RATE,
    FUTURES_MARKET_MANAGER,
    SYSTEM_STATUS
} from "script/utils/parameters/BNBParameters.sol";
import {
    MUMBAI_DEPLOYER,
    MUMBAI_ADMIN_DAO_MULTI_SIG,
    MUMBAI_ADDRESS_RESOLVER,
    MUMBAI_GELATO,
    MUMBAI_AUTOMATE
} from "script/utils/parameters/MumbaiParameters.sol";

import {
    SEPOLIA_DEPLOYER,
    SEPOLIA_ADMIN_DAO_MULTI_SIG,
    SEPOLIA_ADDRESS_RESOLVER,
    SEPOLIA_GELATO,
    SEPOLIA_AUTOMATE
} from "script/utils/parameters/SepoliaParameters.sol";

/// @title Script to deploy Horizon Protocol Margin Account Factory
contract Setup {
    function deploySystem(
        address _deployer,
        address _owner,
        address _addressResolver,
        address _gelato,
        address _automate
    )
        public
        returns (
            Factory factory,
            Events events,
            Settings settings,
            Account implementation
        )
    {
        IAddressResolver addressResolver;

        // define *initial* factory owner
        address temporaryOwner =
            _deployer == address(0) ? address(this) : _deployer;

        // deploy the factory
        factory = new Factory({_owner: temporaryOwner});

        // deploy the events contract and set the factory
        events = new Events({_factory: address(factory)});

        // deploy the settings contract
        settings = new Settings({_owner: _owner});

        // resolve necessary addresses via the Horizon Protocol Address Resolver
        addressResolver = IAddressResolver(_addressResolver);

        IAccount.AccountConstructorParams memory params = IAccount
            .AccountConstructorParams({
            factory: address(factory),
            events: address(events),
            marginAsset: addressResolver.getAddress({name: PROXY_ZUSD}),
            perpsV2ExchangeRate: addressResolver.getAddress({
                name: PERPS_V2_EXCHANGE_RATE
            }),
            futuresMarketManager: addressResolver.getAddress({
                name: FUTURES_MARKET_MANAGER
            }),
            systemStatus: addressResolver.getAddress({name: SYSTEM_STATUS}),
            gelato: _gelato,
            automate: _automate,
            settings: address(settings)
        });

        implementation = new Account(params);

        // update the factory with the new account implementation
        factory.upgradeAccountImplementation({
            _implementation: address(implementation)
        });

        // transfer ownership of the factory to the owner
        factory.transferOwnership({newOwner: _owner});
    }
}

/// @dev steps to deploy and verify on BNB:
/// (1) load the variables in the .env file via `source .env`
/// (2) run `forge script script/Deploy.s.sol:DeployBNB --rpc-url $ARCHIVE_NODE_URL_L2 --broadcast --verify -vvvv`
contract DeployBNB is Script, Setup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Setup.deploySystem({
            _deployer: BNB_DEPLOYER,
            _owner: BNB_PDAO,
            _addressResolver: BNB_ADDRESS_RESOLVER,
            _gelato: BNB_GELATO,
            _automate: BNB_AUTOMATE
        });

        vm.stopBroadcast();
    }
}

/// @dev steps to deploy and verify on Mumbai:
/// (1) load the variables in the .env file via `source .env`
/// (2) run `forge script script/Deploy.s.sol:DeployMumbai --rpc-url $ARCHIVE_NODE_URL_GOERLI_L2 --broadcast --verify -vvvv`
contract DeployMumbai is Script, Setup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Setup.deploySystem({
            _deployer: MUMBAI_DEPLOYER,
            _owner: MUMBAI_ADMIN_DAO_MULTI_SIG,
            _addressResolver: MUMBAI_ADDRESS_RESOLVER,
            _gelato: MUMBAI_GELATO,
            _automate: MUMBAI_AUTOMATE
        });

        vm.stopBroadcast();
    }
}

/// @dev steps to deploy and verify on Sepolia:
/// (1) load the variables in the .env file via `source .env`
/// (2) run `forge script script/Deploy.s.sol:DeploySepolia --rpc-url $ARCHIVE_NODE_URL_GOERLI_L2 --broadcast --verify -vvvv`
contract DeploySepolia is Script, Setup {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        Setup.deploySystem({
            _deployer: SEPOLIA_DEPLOYER,
            _owner: SEPOLIA_ADMIN_DAO_MULTI_SIG,
            _addressResolver: SEPOLIA_ADDRESS_RESOLVER,
            _gelato: SEPOLIA_GELATO,
            _automate: SEPOLIA_AUTOMATE
        });

        vm.stopBroadcast();
    }
}
