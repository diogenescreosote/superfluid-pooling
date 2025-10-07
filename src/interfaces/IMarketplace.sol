// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IMarketplace
 * @dev Interface for auction marketplace (thirdweb V3 compatible)
 */
interface IMarketplace {
    struct ListingParameters {
        address assetContract;
        uint256 tokenId;
        uint256 startTime;
        uint256 secondsUntilEndTime;
        uint256 quantityToList;
        address currencyToAccept;
        uint256 reservePrice;
        uint256 buyoutPrice;
        uint8 listingType; // 0 = Direct, 1 = Auction
    }

    struct Listing {
        uint256 listingId;
        address tokenOwner;
        address assetContract;
        uint256 tokenId;
        uint256 startTime;
        uint256 endTime;
        uint256 quantity;
        address currency;
        uint256 reservePrice;
        uint256 buyoutPrice;
        uint8 tokenType;
        uint8 listingType;
    }

    struct Offer {
        uint256 listingId;
        address offeror;
        uint256 quantityWanted;
        address currency;
        uint256 pricePerToken;
        uint256 expirationTimestamp;
    }

    event ListingAdded(
        uint256 indexed listingId,
        address indexed assetContract,
        address indexed lister,
        Listing listing
    );

    event NewOffer(
        uint256 indexed listingId,
        address indexed offeror,
        uint8 indexed listingType,
        uint256 quantityWanted,
        uint256 totalOfferAmount,
        address currency
    );

    event NewSale(
        uint256 indexed listingId,
        address indexed assetContract,
        address indexed lister,
        address buyer,
        uint256 quantityBought,
        uint256 totalPricePaid
    );

    event AuctionClosed(
        uint256 indexed listingId,
        address indexed closer,
        bool indexed cancelled,
        address auctionCreator,
        address winningBidder
    );

    /**
     * @dev Create a new listing
     */
    function createListing(ListingParameters calldata params) external returns (uint256 listingId);

    /**
     * @dev Make an offer on a listing
     */
    function offer(
        uint256 listingId,
        uint256 quantityWanted,
        address currency,
        uint256 pricePerToken,
        uint256 expirationTimestamp
    ) external;

    /**
     * @dev Close an auction
     */
    function closeAuction(uint256 listingId, address closeFor) external;

    /**
     * @dev Get listing details
     */
    function listings(uint256 listingId) external view returns (Listing memory);

    /**
     * @dev Get winning bid for an auction
     */
    function winningBid(uint256 listingId) external view returns (
        address bidder,
        address currency,
        uint256 bidAmount
    );

    /**
     * @dev Get all offers for a listing
     */
    function offers(uint256 listingId, address offeror) external view returns (Offer memory);
}

/**
 * @title IAuctionSettlement
 * @dev Interface for handling auction settlement callbacks
 */
interface IAuctionSettlement {
    function onAuctionSettled(
        address collection,
        uint256 tokenId,
        uint256 clearingPrice,
        address winner
    ) external;
}


