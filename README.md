# Horizon Protocol Margin

[![Foundry][foundry-badge]][foundry]
[![License: MIT][license-badge]][license]

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/license/GPL-3.0/
[license-badge]:https://img.shields.io/badge/GitHub-GPL--3.0-informational

## High-Level Overview

Contracts to manage account abstractions and features on top of [Horizon Protocol Perps V2](https://github.com/Horizon-Protocol/Horizon-Smart-Contract/blob/develop/contracts/PerpsV2Market.sol).

### System Diagram

<p align="center">
  <img src="/diagrams/Abstract-System-Diagram.png" width="1000" height="600" alt="System-Diagram"/>
</p>

## Contracts Overview

> See ./deploy-addresses/ for deployed contract addresses

The Margin codebase consists of the `Factory` and `Account` contracts, and all of the associated dependencies. The purpose of the `Factory` is to create/deploy trading accounts (`Account` contracts) for users that support features ranging from cross-margin, conditional orders, copy trading, etc.. Once a smart margin account has been created, the main point of entry is the `Account.execute` function. `Account.execute` allows users to execute a set of commands describing the actions/trades they want executed by their account.

### User Entry: MarginBase Command Execution

Calls to `Account.execute`, the entrypoint to the smart margin account, require 2 main parameters:

`IAccount.Command commands`: An array of `enum`. Each enum represents 1 command that the transaction will execute.
`bytes[] inputs`: An array of `bytes` strings. Each element in the array is the encoded parameters for a command.

`commands[i]` is the command that will use `inputs[i]` as its encoded input parameters.

#### How the input bytes are structured

Each input bytes string is merely the abi encoding of a set of parameters. Depending on the command chosen, the input bytes string will be different. For example:

The inputs for `PERPS_V2_SUBMIT_OFFCHAIN_DELAYED_ORDER` is the encoding of 3 parameters:

`address`: The Horizon Protocol PerpsV2 Market address
`int256`: The size delta of the order to be submitted
`uint256`: The desired fill price of the order

`address`: The Horizon Protocol PerpsV2 Market address which has an active delayed order submitted by this account

Encoding parameters in a bytes string in this way gives us maximum flexiblity to be able to support many commands which require different datatypes in a gas-efficient way.

For a more detailed breakdown of which parameters you should provide for each command take a look at the `Account.dispatch` function.

#### Diagram

<p align="center">
  <img src="/diagrams/Execution-Flow.png" alt="Execution-Flow"/>
</p>

#### Reference

The command execution design was inspired by Uniswap's [Universal Router](https://github.com/Uniswap/universal-router).

### Events

Certain actions performed by the margin account emit events (such as depositing margin, or placing a conditional order). These events can be used to track the state of the account and to monitor the account's activity. To avoid monitoring a large number of accounts for events, we consolidate all events into a single `Events' contract`. Margin accounts make external calls to the `Events` contract to emit events. This costs more gas, but significantly reduces the load on our event monitoring infrastructure.

### Orders

The term "order" is used often in this codebase. Margin accounts natively define conditional orders, which include limit orders, stop-loss orders, and redcue-only flavors of the former two. It also supports a variety of other Horizon-Protocol PerpsV2 orders which are explicity defined by `IAccount.Command commands`.

### Upgradability

Margin accounts are upgradable. This is achieved by using a proxy pattern, where the `Account` contract is the implementation and the `AccountProxy` contract is the proxy. The `AccountProxy` contract is the contract that is deployed by the `Factory` and is the contract that users interact with. The `AccountProxy` contract delegates all calls to the `Account` contract. The `Account` contract can be upgraded by the `Factory` contract due to the `Factory` acting as a Beacon contract for the proxy. See further details on Beacons [here](https://docs.openzeppelin.com/contracts/3.x/api/proxy#beacon). One important difference between the standard Beacon implementation and our own, is that the Beacon (i.e. the `Factory`) is _not_ upgradeable. This is to prevent the Beacon from being upgraded and the proxy implementation being changed to a malicious contract.

Finally, all associated functionality related to upgradability can be disabled by the `Factory` contract owner.

## Folder Structure
> to run: `tree src/`

```
src/
├── Account.sol
├── AccountProxy.sol
├── Events.sol
├── Factory.sol
├── Settings.sol
├── interfaces
│   ├── IAccount.sol
│   ├── IAccountProxy.sol
│   ├── IEvents.sol
│   ├── IFactory.sol
│   ├── ISettings.sol
│   ├── horizon-protocol
│   │   ├── IFuturesMarketManager.sol
│   │   ├── IPerpsV2ExchangeRate.sol
│   │   ├── IPerpsV2MarketConsolidated.sol
│   │   └── ISystemStatus.sol
└── utils
    ├── Auth.sol
    ├── Owned.sol
    ├── gelato
    │   ├── AutomateReady.sol
    │   └── AutomateTaskCreator.sol
    ├── openzeppelin
    │   └── IERC20.sol
```

## Usage

### Setup

1. Make sure to create an `.env` file following the example given in `.env.example`

2. Install [Slither](https://github.com/crytic/slither#how-to-install)

### Tests

#### Running Tests

1. Follow the [Foundry guide to working on an existing project](https://book.getfoundry.sh/projects/working-on-an-existing-project.html)

2. Build project

```
npm run compile
```

3. Execute both unit and integration tests (both run in forked environments)

```
npm run test
```

4. Run specific test

```
forge test --fork-url $(grep ARCHIVE_NODE_URL .env | cut -d '=' -f2) --match-test TEST_NAME -vvv
```

> tests will fail if you have not set up your .env (see .env.example)

### Upgradability

> Upgrades can be dangerous. Please ensure you have a good understanding of the implications of upgrading your contracts before proceeding. Storage collisions, Function signature collisions, and other issues can occur.

#### Update Account Implementation

> note that updates to `Account` are reflected in all smart margin accounts, regardless of whether they were created before or after the `Account` upgrade.

1. Update `Account.sol` contract
> Make sure to update version number in `Account.sol` contract
2. Add new directory to `./script/upgrades/` with the version number as the directory name (i.e. v2.6.9)
3. Create new `Upgrade.s.sol` for the new version in that directory
4. Add new directory to `./test/upgrades/` with the version number as the directory name (i.e. v2.6.9)
5. Create new `Upgrade.t.sol` for the new version in that directory
6. Test upgrade using new script (example: `./test/upgrades/v2.0.1/Upgrade.t.sol`)
7. Run script and deploy to Testnet
8. Call `Factory.upgradeAccountImplementation` with new `Account` address (can be done on etherscan)
> Only factory owner can do this
9. Update `./deploy-addresses/mumbai.json` with new `Account` address
10. Ensure testnet accounts are updated and functional (ensure state is correct)
11. Run script and deploy to Mainnet
12. Call `Factory.upgradeAccountImplementation` with new `Account` address (can be done on etherscan)
> Only factory owner can do this (pDAO)
13. Update `./deploy-addresses/bnb-mainnet.json` with new `Account` address
14. Ensure mainnet accounts are updated and functional (ensure state is correct)

## Project Tools

### Static Analysis

1. [Slither](https://github.com/crytic/slither)

```
npm run analysis:slither
```

2. [Solsat](https://github.com/0xKitsune/solstat)

```
npm run analysis:solsat
```

### Formatting

1. Project uses Foundry's formatter:

```
npm run format
```

### Code Coverage

1. Project uses Foundry's code coverage tool:

```
npm run coverage
```

### Gas Snapshot
> Snapshots should be updated after every contract change

1. Project uses Foundry's gas snapshot tool:

```
npm run gas-snapshot
```

2. To view the gas snapshot, navigate to `./gas-snapshot`
