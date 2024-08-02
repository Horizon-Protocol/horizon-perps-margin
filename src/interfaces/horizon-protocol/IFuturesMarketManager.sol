// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.18;

interface IFuturesMarketManager {
    struct MarketSummary {
        address market;
        bytes32 asset;
        bytes32 marketKey;
        uint price;
        uint marketSize;
        int marketSkew;
        uint marketDebt;
        int currentFundingRate;
        int currentFundingVelocity;
        bool priceInvalid;
        bool proxied;
    }

    function marketForKey(bytes32 marketKey) external view returns (address);
    function allMarketSummaries() external view returns (MarketSummary[] memory);
}
