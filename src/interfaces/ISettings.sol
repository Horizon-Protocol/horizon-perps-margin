// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

/// @title Horizon Protocol Margin Account Settings Interface
interface ISettings {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice emitted when account execution is enabled or disabled
    /// @param enabled: true if account execution is enabled, false if disabled
    event AccountExecutionEnabledSet(bool enabled);

    /// @notice emitted when the executor fee is updated
    /// @param executorFee: the executor fee
    event ExecutorFeeSet(uint256 executorFee);

    /// @notice emitted when a token is added to or removed from the whitelist
    /// @param token: address of the token
    /// @param isWhitelisted: true if token is whitelisted, false if not
    event TokenWhitelistStatusUpdated(address token, bool isWhitelisted);

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice checks if account execution is enabled or disabled
    /// @return enabled: true if account execution is enabled, false if disabled
    function accountExecutionEnabled() external view returns (bool);

    /// @notice gets the conditional order executor fee
    /// @return executorFee: the executor fee
    function executorFee() external view returns (uint256);

    /// @notice checks if token is whitelisted
    /// @param _token: address of the token to check
    /// @return true if token is whitelisted, false if not
    function isTokenWhitelisted(address _token) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice enables or disables account execution
    /// @param _enabled: true if account execution is enabled, false if disabled
    function setAccountExecutionEnabled(bool _enabled) external;

    /// @notice sets the conditional order executor fee
    /// @param _executorFee: the executor fee
    function setExecutorFee(uint256 _executorFee) external;

    /// @notice adds/removes token to/from whitelist
    /// @dev does not check if token was previously whitelisted
    /// @param _token: address of the token to add
    /// @param _isWhitelisted: true if token is to be whitelisted, false if not
    function setTokenWhitelistStatus(address _token, bool _isWhitelisted)
        external;
}
