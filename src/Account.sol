// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

import {Auth} from "src/utils/Auth.sol";
import {
    IAccount, IPerpsV2MarketConsolidated
} from "src/interfaces/IAccount.sol";
import {IFactory} from "src/interfaces/IFactory.sol";
import {IFuturesMarketManager} from
    "src/interfaces/horizon-protocol/IFuturesMarketManager.sol";
import {ISettings} from "src/interfaces/ISettings.sol";
import {ISystemStatus} from "src/interfaces/horizon-protocol/ISystemStatus.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {IPerpsV2ExchangeRate} from
    "src/interfaces/horizon-protocol/IPerpsV2ExchangeRate.sol";
import {AutomateTaskCreator} from "src/utils/gelato/AutomateTaskCreator.sol";
import "src/utils/gelato/Types.sol";
import {IERC20} from "src/utils/openzeppelin/IERC20.sol";
import {SafeERC20} from "src/utils/openzeppelin/SafeERC20.sol";

/// @title Horizon Protocol Margin Account Implementation
/// @notice flexible margin account enabling users to trade on-chain derivatives
contract Account is IAccount, Auth, AutomateTaskCreator {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    bytes32 public constant VERSION = "1.0.0";

    /// @notice used to ensure the pyth provided price is sufficiently recent
    /// @dev price cannot be older than MAX_PRICE_LATENCY seconds
    uint256 internal constant MAX_PRICE_LATENCY = 120;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice address of the Margin Account Factory
    IFactory internal immutable FACTORY;

    /// @notice address of the contract used by all accounts for emitting events
    /// @dev can be immutable due to the fact the events contract is
    /// upgraded alongside the account implementation
    IEvents internal immutable EVENTS;

    /// @notice address of the Horizon Protocol ProxyERC20zUSD contract used as the margin asset
    /// @dev can be immutable due to the fact the zUSD contract is a proxy address
    IERC20 internal immutable MARGIN_ASSET;

    /// @notice address of the Horizon Protocol PerpsV2ExchangeRate
    /// @dev used internally by Horizon Protocol Perps V2 contracts to retrieve asset exchange rates
    IPerpsV2ExchangeRate internal immutable PERPS_V2_EXCHANGE_RATE;

    /// @notice address of the Horizon Protocol FuturesMarketManager
    /// @dev the manager keeps track of which markets exist, and is the main window between
    /// perpsV2 markets and the rest of the horizon-protocol system. It accumulates the total debt
    /// over all markets, and issues and burns zUSD on each market's behalf
    IFuturesMarketManager internal immutable FUTURES_MARKET_MANAGER;

    /// @notice address of the Horizon Protocol SystemStatus
    /// @dev the system status contract is used to check if the system is operational
    ISystemStatus internal immutable SYSTEM_STATUS;

    /// @notice address of contract used to store global settings
    ISettings internal immutable SETTINGS;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    uint256 public committedMargin;

    /// @inheritdoc IAccount
    uint256 public conditionalOrderId;

    /// @notice track conditional orders by id
    mapping(uint256 id => ConditionalOrder order) internal conditionalOrders;

    /// @notice value used for reentrancy protection
    /// @dev nonReentrant checks that locked is NOT EQUAL to 2
    uint256 internal locked;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier isAccountExecutionEnabled() {
        if (!SETTINGS.accountExecutionEnabled()) {
            revert AccountExecutionDisabled();
        }

        _;
    }

    modifier nonReentrant() {
        /// @dev locked is intially set to 0 due to the proxy nature of margin accounts
        /// however after the inital call to nonReentrant(), locked will be set to 1
        if (locked == 2) revert Reentrancy();
        locked = 2;

        _;

        locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev set owner of implementation to zero address
    /// @param _params: constructor parameters (see IAccount.sol)
    constructor(AccountConstructorParams memory _params)
        Auth(address(0))
        AutomateTaskCreator(_params.automate)
    {
        FACTORY = IFactory(_params.factory);
        EVENTS = IEvents(_params.events);
        MARGIN_ASSET = IERC20(_params.marginAsset);
        PERPS_V2_EXCHANGE_RATE =
            IPerpsV2ExchangeRate(_params.perpsV2ExchangeRate);
        FUTURES_MARKET_MANAGER =
            IFuturesMarketManager(_params.futuresMarketManager);
        SYSTEM_STATUS = ISystemStatus(_params.systemStatus);
        SETTINGS = ISettings(_params.settings);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    function getDelayedOrder(bytes32 _marketKey)
        external
        view
        override
        returns (IPerpsV2MarketConsolidated.DelayedOrder memory order)
    {
        // fetch delayed order data from Horizon Protocol
        order = _getPerpsV2Market(_marketKey).delayedOrders(address(this));
    }

    /// @inheritdoc IAccount
    function checker(uint256 _conditionalOrderId)
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        canExec = _validConditionalOrder(_conditionalOrderId);

        // calldata for execute func
        execPayload =
            abi.encodeCall(this.executeConditionalOrder, _conditionalOrderId);
    }

    /// @inheritdoc IAccount
    function freeMargin() public view override returns (uint256) {
        return MARGIN_ASSET.balanceOf(address(this)) - committedMargin;
    }

    /// @inheritdoc IAccount
    function getPosition(bytes32 _marketKey)
        public
        view
        override
        returns (IPerpsV2MarketConsolidated.Position memory position)
    {
        // fetch position data from Horizon Protocol
        position = _getPerpsV2Market(_marketKey).positions(address(this));
    }

    /// @inheritdoc IAccount
    function getConditionalOrder(uint256 _conditionalOrderId)
        public
        view
        override
        returns (ConditionalOrder memory)
    {
        return conditionalOrders[_conditionalOrderId];
    }

    function validLimitOrder(uint256 _conditionalOrderId)
        public
        view
        returns (bool)
    {
        ConditionalOrder memory conditionalOrder =
            getConditionalOrder(_conditionalOrderId);

        /// @dev if marketKey is invalid, this will revert
        (uint256 price,) =
            _zUSDRate(_getPerpsV2Market(conditionalOrder.marketKey));

        return _validLimitOrder(conditionalOrder, price);
    }

    function validStopOrder(uint256 _conditionalOrderId)
        public
        view
        returns (bool)
    {
        ConditionalOrder memory conditionalOrder =
            getConditionalOrder(_conditionalOrderId);

        /// @dev if marketKey is invalid, this will revert
        (uint256 price,) =
            _zUSDRate(_getPerpsV2Market(conditionalOrder.marketKey));

        return _validStopOrder(conditionalOrder, price);
    }

    /*//////////////////////////////////////////////////////////////
                               OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    function setInitialOwnership(address _owner) external override {
        if (msg.sender != address(FACTORY)) revert Unauthorized();

        /// @dev set owner directly
        owner = _owner;

        EVENTS.emitOwnershipTransferred({caller: address(0), newOwner: _owner});
    }

    /// @inheritdoc Auth
    function transferOwnership(address _newOwner) public override {
        require(_newOwner != address(0));

        // will revert if msg.sender is *NOT* owner
        super.transferOwnership(_newOwner);

        // update the factory's record of owners and account addresses
        FACTORY.updateAccountOwnership({
            _newOwner: _newOwner,
            _oldOwner: msg.sender // verified to be old owner
        });

        /// @notice previous owner was verified to be msg.sender
        EVENTS.emitOwnershipTransferred({
            caller: msg.sender,
            newOwner: _newOwner
        });
    }

    /*//////////////////////////////////////////////////////////////
                               DELEGATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc Auth
    function addDelegate(address _delegate) public override {
        // will revert if msg.sender is *NOT* owner
        super.addDelegate(_delegate);

        EVENTS.emitDelegatedAccountAdded({
            caller: msg.sender,
            delegate: _delegate
        });
    }

    /// @inheritdoc Auth
    function removeDelegate(address _delegate) public override {
        // will revert if msg.sender is *NOT* owner
        super.removeDelegate(_delegate);

        EVENTS.emitDelegatedAccountRemoved({
            caller: msg.sender,
            delegate: _delegate
        });
    }

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    function execute(Command[] calldata _commands, bytes[] calldata _inputs)
        external
        payable
        override
        nonReentrant
        isAccountExecutionEnabled
    {
        uint256 numCommands = _commands.length;
        if (_inputs.length != numCommands) {
            revert LengthMismatch();
        }

        // loop through all given commands and execute them
        for (uint256 commandIndex = 0; commandIndex < numCommands;) {
            _dispatch(_commands[commandIndex], _inputs[commandIndex]);
            unchecked {
                ++commandIndex;
            }
        }
    }

    /// @notice Decodes and executes the given command with the given inputs
    /// @param _command: The command type to execute
    /// @param _inputs: The inputs to execute the command with
    function _dispatch(Command _command, bytes calldata _inputs) internal {
        uint256 commandIndex = uint256(_command);

        if (commandIndex < 2) {
            /// @dev only owner can execute the following commands
            if (!isOwner()) revert Unauthorized();

            if (_command == Command.ACCOUNT_MODIFY_MARGIN) {
                // Command.ACCOUNT_MODIFY_MARGIN
                int256 amount;
                assembly {
                    amount := calldataload(_inputs.offset)
                }
                _modifyAccountMargin({_amount: amount});
            } else {
                // Command.ACCOUNT_WITHDRAW_ETH
                uint256 amount;
                assembly {
                    amount := calldataload(_inputs.offset)
                }
                _withdrawEth({_amount: amount});
            }
        } else {
            /// @dev only owner and delegate(s) can execute the following commands
            if (!isAuth()) revert Unauthorized();

            if (commandIndex < 4) {
                if (_command == Command.PERPS_V2_MODIFY_MARGIN) {
                    // Command.PERPS_V2_MODIFY_MARGIN
                    address market;
                    int256 amount;
                    assembly {
                        market := calldataload(_inputs.offset)
                        amount := calldataload(add(_inputs.offset, 0x20))
                    }
                    _perpsV2ModifyMargin({_market: market, _amount: amount});
                } else {
                    // Command.PERPS_V2_WITHDRAW_ALL_MARGIN
                    address market;
                    assembly {
                        market := calldataload(_inputs.offset)
                    }
                    _perpsV2WithdrawAllMargin({_market: market});
                }
            } else if (commandIndex < 7) {
                if (_command == Command.PERPS_V2_SUBMIT_OFFCHAIN_DELAYED_ORDER)
                {
                    // Command.PERPS_V2_SUBMIT_OFFCHAIN_DELAYED_ORDER
                    address market;
                    int256 sizeDelta;
                    uint256 desiredFillPrice;
                    bytes32 trackingCode;
                    assembly {
                        market := calldataload(_inputs.offset)
                        sizeDelta := calldataload(add(_inputs.offset, 0x20))
                        desiredFillPrice :=
                            calldataload(add(_inputs.offset, 0x40))
                        trackingCode := calldataload(add(_inputs.offset, 0x60))
                    }
                    _perpsV2SubmitOffchainDelayedOrder({
                        _market: market,
                        _sizeDelta: sizeDelta,
                        _desiredFillPrice: desiredFillPrice,
                        _trackingCode: trackingCode
                    });
                } else if (
                    _command
                        == Command.PERPS_V2_SUBMIT_CLOSE_OFFCHAIN_DELAYED_ORDER
                ) {
                    // Command.PERPS_V2_SUBMIT_CLOSE_OFFCHAIN_DELAYED_ORDER
                    address market;
                    uint256 desiredFillPrice;
                    bytes32 trackingCode;
                    assembly {
                        market := calldataload(_inputs.offset)
                        desiredFillPrice :=
                            calldataload(add(_inputs.offset, 0x20))
                        trackingCode := calldataload(add(_inputs.offset, 0x40))
                    }
                    _perpsV2SubmitCloseOffchainDelayedOrder({
                        _market: market,
                        _desiredFillPrice: desiredFillPrice,
                        _trackingCode: trackingCode
                    });
                } else {
                    // Command.PERPS_V2_CANCEL_OFFCHAIN_DELAYED_ORDER
                    address market;
                    assembly {
                        market := calldataload(_inputs.offset)
                    }
                    _perpsV2CancelOffchainDelayedOrder({_market: market});
                }
            } else if (commandIndex < 9) {
                if (_command == Command.GELATO_PLACE_CONDITIONAL_ORDER) {
                    // Command.GELATO_PLACE_CONDITIONAL_ORDER
                    bytes32 marketKey;
                    int256 marginDelta;
                    int256 sizeDelta;
                    uint256 targetPrice;
                    ConditionalOrderTypes conditionalOrderType;
                    uint256 desiredFillPrice;
                    bool reduceOnly;
                    bytes32 trackingCode;
                    assembly {
                        marketKey := calldataload(_inputs.offset)
                        marginDelta := calldataload(add(_inputs.offset, 0x20))
                        sizeDelta := calldataload(add(_inputs.offset, 0x40))
                        targetPrice := calldataload(add(_inputs.offset, 0x60))
                        conditionalOrderType :=
                            calldataload(add(_inputs.offset, 0x80))
                        desiredFillPrice :=
                            calldataload(add(_inputs.offset, 0xa0))
                        reduceOnly := calldataload(add(_inputs.offset, 0xc0))
                        trackingCode := calldataload(add(_inputs.offset, 0xe0))
                    }
                    _placeConditionalOrder({
                        _marketKey: marketKey,
                        _marginDelta: marginDelta,
                        _sizeDelta: sizeDelta,
                        _targetPrice: targetPrice,
                        _conditionalOrderType: conditionalOrderType,
                        _desiredFillPrice: desiredFillPrice,
                        _reduceOnly: reduceOnly,
                        _trackingCode: trackingCode
                    });
                } else {
                    // Command.GELATO_CANCEL_CONDITIONAL_ORDER
                    uint256 orderId;
                    assembly {
                        orderId := calldataload(_inputs.offset)
                    }
                    _cancelConditionalOrder({_conditionalOrderId: orderId});
                }
            } else {
                // command indices beyond 16 are invalid
                revert InvalidCommandType(commandIndex);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNT DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice allows ETH to be deposited directly into a margin account
    /// @notice ETH can be withdrawn
    receive() external payable {}

    /// @notice allow users to withdraw ETH deposited for keeper fees
    /// @param _amount: amount to withdraw
    function _withdrawEth(uint256 _amount) internal {
        require(_amount <= address(this).balance);

        if (_amount > 0) {
            (bool success,) = payable(msg.sender).call{value: _amount}("");
            if (!success) revert EthWithdrawalFailed();

            EVENTS.emitEthWithdraw({user: msg.sender, amount: _amount});
        }
    }

    /// @notice deposit/withdraw margin to/from this margin account
    /// @param _amount: amount of margin to deposit/withdraw
    function _modifyAccountMargin(int256 _amount) internal {
        // if amount is positive, deposit
        if (_amount > 0) {
            /// @dev failed Horizon Protocol asset transfer will revert and not return false if unsuccessful
            MARGIN_ASSET.safeTransferFrom(msg.sender, address(this), _abs(_amount));

            EVENTS.emitDeposit({user: msg.sender, amount: _abs(_amount)});
        } else if (_amount < 0) {
            // if amount is negative, withdraw
            _sufficientMargin(_amount);

            /// @dev failed Horizon Protocol asset transfer will revert and not return false if unsuccessful
            MARGIN_ASSET.safeTransfer(msg.sender, _abs(_amount));

            EVENTS.emitWithdraw({user: msg.sender, amount: _abs(_amount)});
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MODIFY MARKET MARGIN
    //////////////////////////////////////////////////////////////*/

    /// @notice deposit/withdraw margin to/from a Horizon Protocol PerpsV2 Market
    /// @param _market: address of market
    /// @param _amount: amount of margin to deposit/withdraw
    function _perpsV2ModifyMargin(address _market, int256 _amount) internal {
        if (_amount > 0) {
            _sufficientMargin(_amount);
        }
        IPerpsV2MarketConsolidated(_market).transferMargin(_amount);
    }

    /// @notice withdraw margin from market back to this account
    /// @dev this will *not* fail if market has zero margin
    function _perpsV2WithdrawAllMargin(address _market) internal {
        IPerpsV2MarketConsolidated(_market).withdrawAllMargin();
    }

    /*//////////////////////////////////////////////////////////////
                        DELAYED OFF-CHAIN ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice submit an off-chain delayed order to a Horizon Protocol PerpsV2 Market
    /// @param _market: address of market
    /// @param _sizeDelta: size delta of order
    /// @param _desiredFillPrice: desired fill price of order
    /// @param _trackingCode: tracking code of exchange
    function _perpsV2SubmitOffchainDelayedOrder(
        address _market,
        int256 _sizeDelta,
        uint256 _desiredFillPrice,
        bytes32 _trackingCode
    ) internal {
        IPerpsV2MarketConsolidated(_market)
            .submitOffchainDelayedOrderWithTracking({
            sizeDelta: _sizeDelta,
            desiredFillPrice: _desiredFillPrice,
            trackingCode: _trackingCode
        });
    }

    /// @notice cancel a *pending* off-chain delayed order from a Horizon Protocol PerpsV2 Market
    /// @dev will revert if no previous offchain delayed order
    function _perpsV2CancelOffchainDelayedOrder(address _market) internal {
        IPerpsV2MarketConsolidated(_market).cancelOffchainDelayedOrder(
            address(this)
        );
    }

    /// @notice close Horizon Protocol PerpsV2 Market position via an offchain delayed order
    /// @param _market: address of market
    /// @param _desiredFillPrice: desired fill price of order
    /// @param _trackingCode: tracking code of the exchange
    function _perpsV2SubmitCloseOffchainDelayedOrder(
        address _market,
        uint256 _desiredFillPrice,
        bytes32 _trackingCode
    ) internal {
        // close position (i.e. reduce size to zero)
        /// @dev this does not remove margin from market
        IPerpsV2MarketConsolidated(_market)
            .submitCloseOffchainDelayedOrderWithTracking({
            desiredFillPrice: _desiredFillPrice,
            trackingCode: _trackingCode
        });
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE CONDITIONAL ORDER
    //////////////////////////////////////////////////////////////*/

    /// @notice register a conditional order internally and with gelato
    /// @dev restricts _sizeDelta to be non-zero otherwise no need for conditional order
    /// @param _marketKey: Horizon Protocol futures market id/key
    /// @param _marginDelta: amount of margin (in zUSD) to deposit or withdraw
    /// @param _sizeDelta: denominated in market currency (i.e. ETH, BTC, etc), size of position
    /// @param _targetPrice: expected conditional order price
    /// @param _conditionalOrderType: expected conditional order type enum where 0 = LIMIT, 1 = STOP, etc..
    /// @param _desiredFillPrice: desired price to fill Horizon Protocol PerpsV2 order at execution time
    /// @param _reduceOnly: if true, only allows position's absolute size to decrease
    /// @param _trackingCode: _tracking code of the exchange
    function _placeConditionalOrder(
        bytes32 _marketKey,
        int256 _marginDelta,
        int256 _sizeDelta,
        uint256 _targetPrice,
        ConditionalOrderTypes _conditionalOrderType,
        uint256 _desiredFillPrice,
        bool _reduceOnly,
        bytes32 _trackingCode
    ) internal {
        if (_sizeDelta == 0) revert ZeroSizeDelta();

        // if more margin is desired on the position we must commit the margin
        if (_marginDelta > 0) {
            _sufficientMargin(_marginDelta);
            committedMargin += _abs(_marginDelta);
        }

        // create and submit Gelato task for this conditional order
        bytes32 taskId = _createGelatoTask();

        // internally store the conditional order
        conditionalOrders[conditionalOrderId] = ConditionalOrder({
            marketKey: _marketKey,
            marginDelta: _marginDelta,
            sizeDelta: _sizeDelta,
            targetPrice: _targetPrice,
            gelatoTaskId: taskId,
            conditionalOrderType: _conditionalOrderType,
            desiredFillPrice: _desiredFillPrice,
            reduceOnly: _reduceOnly,
            trackingCode: _trackingCode
        });

        EVENTS.emitConditionalOrderPlaced({
            conditionalOrderId: conditionalOrderId,
            gelatoTaskId: taskId,
            marketKey: _marketKey,
            marginDelta: _marginDelta,
            sizeDelta: _sizeDelta,
            targetPrice: _targetPrice,
            conditionalOrderType: _conditionalOrderType,
            desiredFillPrice: _desiredFillPrice,
            reduceOnly: _reduceOnly
        });

        ++conditionalOrderId;
    }

    /// @notice create a new Gelato task for a conditional order
    /// @return taskId of the new Gelato task
    function _createGelatoTask() internal returns (bytes32 taskId) {
        ModuleData memory moduleData = _createGelatoModuleData();

        taskId = _createTask({
            _execAddress: address(this),
            _execDataOrSelector: abi.encodeCall(
                this.executeConditionalOrder, conditionalOrderId
                ),
            _moduleData: moduleData,
            _feeToken: ETH
        });
    }

    /// @notice create the Gelato ModuleData for a conditional order
    /// @dev see IAutomate for details on the task creation and the ModuleData struct
    function _createGelatoModuleData()
        internal
        view
        returns (ModuleData memory moduleData)
    {
        moduleData =
            ModuleData({modules: new Module[](2), args: new bytes[](2)});

        moduleData.modules[0] = Module.RESOLVER;
        moduleData.modules[1] = Module.PROXY;

        moduleData.args[0] = _resolverModuleArg(
            address(this), abi.encodeCall(this.checker, conditionalOrderId)
        );
        moduleData.args[1] = _proxyModuleArg();
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL CONDITIONAL ORDER
    //////////////////////////////////////////////////////////////*/

    /// @notice cancel a gelato queued conditional order
    /// @param _conditionalOrderId: key for an active conditional order
    function _cancelConditionalOrder(uint256 _conditionalOrderId) internal {
        ConditionalOrder memory conditionalOrder =
            getConditionalOrder(_conditionalOrderId);

        // if margin was committed, free it
        if (conditionalOrder.marginDelta > 0) {
            committedMargin -= _abs(conditionalOrder.marginDelta);
        }

        // cancel gelato task
        /// @dev will revert if task id does not exist {Automate.cancelTask: Task not found}
        _cancelTask(conditionalOrder.gelatoTaskId);

        // delete order from conditional orders
        delete conditionalOrders[_conditionalOrderId];

        EVENTS.emitConditionalOrderCancelled({
            conditionalOrderId: _conditionalOrderId,
            gelatoTaskId: conditionalOrder.gelatoTaskId,
            reason: ConditionalOrderCancelledReason
                .CONDITIONAL_ORDER_CANCELLED_BY_USER
        });
    }

    /*//////////////////////////////////////////////////////////////
                       EXECUTE CONDITIONAL ORDER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    function executeConditionalOrder(uint256 _conditionalOrderId)
        external
        override
        nonReentrant
        isAccountExecutionEnabled
    {
        // verify conditional order is ready for execution
        /// @dev it is understood this is a duplicate check if the executor is Gelato
        if (!_validConditionalOrder(_conditionalOrderId)) {
            revert CannotExecuteConditionalOrder({
                conditionalOrderId: _conditionalOrderId,
                executor: msg.sender
            });
        }

        // store conditional order object in memory
        ConditionalOrder memory conditionalOrder =
            getConditionalOrder(_conditionalOrderId);

        // remove conditional order from internal accounting
        delete conditionalOrders[_conditionalOrderId];

        // remove gelato task from their accounting
        /// @dev will revert if task id does not exist {Automate.cancelTask: Task not found}
        /// @dev if executor is not Gelato, the task will still be cancelled
        _cancelTask(conditionalOrder.gelatoTaskId);

        // impose and record fee paid to executor
        uint256 fee = _payExecutorFee();

        // define Horizon Protocol PerpsV2 market
        IPerpsV2MarketConsolidated market =
            _getPerpsV2Market(conditionalOrder.marketKey);

        /// @dev conditional order is valid given checker() returns true; define fill price
        (uint256 fillPrice, PriceOracleUsed priceOracle) = _zUSDRate(market);

        // if conditional order is reduce only, ensure position size is only reduced
        if (conditionalOrder.reduceOnly) {
            int256 currentSize = market.positions({account: address(this)}).size;

            // ensure position exists and incoming size delta is NOT the same sign
            /// @dev if incoming size delta is the same sign, then the conditional order is not reduce only
            if (
                currentSize == 0
                    || _isSameSign(currentSize, conditionalOrder.sizeDelta)
            ) {
                EVENTS.emitConditionalOrderCancelled({
                    conditionalOrderId: _conditionalOrderId,
                    gelatoTaskId: conditionalOrder.gelatoTaskId,
                    reason: ConditionalOrderCancelledReason
                        .CONDITIONAL_ORDER_CANCELLED_NOT_REDUCE_ONLY
                });

                return;
            }

            // ensure incoming size delta is not larger than current position size
            /// @dev reduce only conditional orders can only reduce position size (i.e. approach size of zero) and
            /// cannot cross that boundary (i.e. short -> long or long -> short)
            if (_abs(conditionalOrder.sizeDelta) > _abs(currentSize)) {
                // bound conditional order size delta to current position size
                conditionalOrder.sizeDelta = -currentSize;
            }
        }

        // if margin was committed, free it
        if (conditionalOrder.marginDelta > 0) {
            committedMargin -= _abs(conditionalOrder.marginDelta);
        }

        // execute trade
        _perpsV2ModifyMargin({
            _market: address(market),
            _amount: conditionalOrder.marginDelta
        });

        _perpsV2SubmitOffchainDelayedOrder({
            _market: address(market),
            _sizeDelta: conditionalOrder.sizeDelta,
            _desiredFillPrice: conditionalOrder.desiredFillPrice,
            _trackingCode: conditionalOrder.trackingCode
        });

        EVENTS.emitConditionalOrderFilled({
            conditionalOrderId: _conditionalOrderId,
            gelatoTaskId: conditionalOrder.gelatoTaskId,
            fillPrice: fillPrice,
            keeperFee: fee,
            priceOracle: priceOracle
        });
    }

    /// @notice pay fee for conditional order execution
    /// @dev fee will be different depending on executor
    /// @return fee amount paid
    function _payExecutorFee() internal returns (uint256 fee) {
        address feeToken;
        (fee, feeToken) = _getFeeDetails();

        if (fee != 0 && feeToken != address(0)) {
            _transfer(fee, feeToken);
        }
        else {
            fee = SETTINGS.executorFee();
            (bool success,) = msg.sender.call{value: fee}("");
            if (!success) revert CannotPayExecutorFee(fee, msg.sender);
        }
    }

    /// @notice order logic condition checker
    /// @dev this is where order type logic checks are handled
    /// @param _conditionalOrderId: key for an active order
    /// @return true if conditional order is valid by execution rules
    function _validConditionalOrder(uint256 _conditionalOrderId)
        internal
        view
        returns (bool)
    {
        ConditionalOrder memory conditionalOrder =
            getConditionalOrder(_conditionalOrderId);

        // return false if market key is the default value (i.e. "")
        if (conditionalOrder.marketKey == bytes32(0)) {
            return false;
        }

        // return false if market is paused
        try SYSTEM_STATUS.requireFuturesMarketActive(conditionalOrder.marketKey)
        {} catch {
            return false;
        }

        /// @dev if marketKey is invalid, this will revert
        (uint256 price,) =
            _zUSDRate(_getPerpsV2Market(conditionalOrder.marketKey));

        // check if markets satisfy specific order type
        if (
            conditionalOrder.conditionalOrderType == ConditionalOrderTypes.LIMIT
        ) {
            return _validLimitOrder(conditionalOrder, price);
        } else if (
            conditionalOrder.conditionalOrderType == ConditionalOrderTypes.STOP
        ) {
            return _validStopOrder(conditionalOrder, price);
        }

        // unknown order type
        return false;
    }

    /// @notice limit order logic condition checker
    /// @dev sizeDelta will never be zero due to check when submitting conditional order
    /// @param _conditionalOrder: struct for an active conditional order
    /// @param _price: current price of market asset
    /// @return true if conditional order is valid by execution rules
    function _validLimitOrder(
        ConditionalOrder memory _conditionalOrder,
        uint256 _price
    ) internal pure returns (bool) {
        if (_conditionalOrder.sizeDelta > 0) {
            // Long: increase position size (buy) once *below* target price
            // ex: open long position once price is below target
            return _price <= _conditionalOrder.targetPrice;
        } else {
            // Short: decrease position size (sell) once *above* target price
            // ex: open short position once price is above target
            return _price >= _conditionalOrder.targetPrice;
        }
    }

    /// @notice stop order logic condition checker
    /// @dev sizeDelta will never be zero due to check when submitting order
    /// @param _conditionalOrder: struct for an active conditional order
    /// @param _price: current price of market asset
    /// @return true if conditional order is valid by execution rules
    function _validStopOrder(
        ConditionalOrder memory _conditionalOrder,
        uint256 _price
    ) internal pure returns (bool) {
        if (_conditionalOrder.sizeDelta > 0) {
            // Long: increase position size (buy) once *above* target price
            // ex: unwind short position once price is above target (prevent further loss)
            return _price >= _conditionalOrder.targetPrice;
        } else {
            // Short: decrease position size (sell) once *below* target price
            // ex: unwind long position once price is below target (prevent further loss)
            return _price <= _conditionalOrder.targetPrice;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MARGIN UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice check that margin attempted to be moved/locked is within free margin bounds
    /// @param _marginOut: amount of margin to be moved/locked
    function _sufficientMargin(int256 _marginOut) internal view {
        if (_abs(_marginOut) > freeMargin()) {
            revert InsufficientFreeMargin(freeMargin(), _abs(_marginOut));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice fetch PerpsV2Market market defined by market key
    /// @param _marketKey: key for Horizon Protocol PerpsV2 market
    /// @return market IPerpsV2MarketConsolidated contract interface
    function _getPerpsV2Market(bytes32 _marketKey)
        internal
        view
        returns (IPerpsV2MarketConsolidated market)
    {
        market = IPerpsV2MarketConsolidated(
            FUTURES_MARKET_MANAGER.marketForKey(_marketKey)
        );

        // sanity check
        assert(address(market) != address(0));
    }

    /// @notice get exchange rate of underlying market asset in terms of zUSD
    /// @dev _zUSDRate can only be reached after a successful internal call to _getPerpsV2Market
    /// which will revert if the market address returned is address(0)
    /// @param _market: Horizon Protocol PerpsV2 Market
    /// @return price in zUSD
    function _zUSDRate(IPerpsV2MarketConsolidated _market)
        internal
        view
        returns (uint256, PriceOracleUsed)
    {
        /// @dev will revert if market is invalid
        bytes32 assetId = _market.baseAsset();

        /// @dev can revert if assetId is invalid OR there's no price for the given asset
        (uint256 price, uint256 publishTime) =
            PERPS_V2_EXCHANGE_RATE.resolveAndGetLatestPrice(assetId);

        // resolveAndGetLatestPrice is provide by pyth
        PriceOracleUsed priceOracle = PriceOracleUsed.PYTH;

        // if the price is stale, get the latest price from the market
        // (i.e. Chainlink provided price)
        if (publishTime < block.timestamp - MAX_PRICE_LATENCY) {
            // set price oracle used to Chainlink
            priceOracle = PriceOracleUsed.CHAINLINK;

            // fetch asset price and ensure it is valid
            bool invalid;
            (price, invalid) = _market.assetPrice();
            if (invalid) revert InvalidPrice();
        }

        /// @dev see IPerpsV2ExchangeRates to understand risks associated with this price
        return (price, priceOracle);
    }

    /*//////////////////////////////////////////////////////////////
                             MATH UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice get absolute value of the input, returned as an unsigned number.
    /// @param x: signed number
    /// @return z uint256 absolute value of x
    function _abs(int256 x) internal pure returns (uint256 z) {
        assembly {
            let mask := sub(0, shr(255, x))
            z := xor(mask, add(mask, x))
        }
    }

    /// @notice determines if input numbers have the same sign
    /// @dev asserts that both numbers are not zero
    /// @param x: signed number
    /// @param y: signed number
    /// @return true if same sign, false otherwise
    function _isSameSign(int256 x, int256 y) internal pure returns (bool) {
        assert(x != 0 && y != 0);
        return (x ^ y) >= 0;
    }
}
