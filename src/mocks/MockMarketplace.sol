// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../interfaces/IMarketplace.sol";

/**
 * @title MockMarketplace
 * @dev Mock marketplace for testing auction functionality
 */
contract MockMarketplace is IMarketplace {
    uint256 private _nextListingId = 1;
    
    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => Offer) private _winningBids;
    mapping(uint256 => mapping(address => Offer)) private _offers;
    mapping(uint256 => address[]) private _bidders;
    
    function createListing(ListingParameters calldata params) external override returns (uint256 listingId) {
        listingId = _nextListingId++;
        
        _listings[listingId] = Listing({
            listingId: listingId,
            tokenOwner: msg.sender,
            assetContract: params.assetContract,
            tokenId: params.tokenId,
            startTime: params.startTime,
            endTime: params.startTime + params.secondsUntilEndTime,
            quantity: params.quantityToList,
            currency: params.currencyToAccept,
            reservePrice: params.reservePrice,
            buyoutPrice: params.buyoutPrice,
            tokenType: 1, // ERC721
            listingType: params.listingType
        });
        
        // Transfer NFT to marketplace
        IERC721(params.assetContract).transferFrom(msg.sender, address(this), params.tokenId);
        
        emit ListingAdded(listingId, params.assetContract, msg.sender, _listings[listingId]);
    }
    
    function offer(
        uint256 listingId,
        uint256 quantityWanted,
        address currency,
        uint256 pricePerToken,
        uint256 expirationTimestamp
    ) external override {
        Listing memory listing = _listings[listingId];
        require(listing.listingId != 0, "Listing does not exist");
        require(currency == listing.currency, "Wrong currency");
        
        uint256 totalPrice = pricePerToken * quantityWanted;
        
        // Transfer bid amount from bidder
        IERC20(currency).transferFrom(msg.sender, address(this), totalPrice);
        
        // Store offer
        _offers[listingId][msg.sender] = Offer({
            listingId: listingId,
            offeror: msg.sender,
            quantityWanted: quantityWanted,
            currency: currency,
            pricePerToken: pricePerToken,
            expirationTimestamp: expirationTimestamp
        });
        
        // Update winning bid if this is higher
        if (totalPrice > _winningBids[listingId].pricePerToken * _winningBids[listingId].quantityWanted) {
            _winningBids[listingId] = _offers[listingId][msg.sender];
        }
        
        _bidders[listingId].push(msg.sender);
        
        emit NewOffer(listingId, msg.sender, listing.listingType, quantityWanted, totalPrice, currency);
    }
    
    function closeAuction(uint256 listingId, address closeFor) external override {
        Listing memory listing = _listings[listingId];
        require(listing.listingId != 0, "Listing does not exist");
        require(block.timestamp >= listing.endTime, "Auction not ended");
        
        Offer memory winningOffer = _winningBids[listingId];
        
        if (winningOffer.offeror != address(0)) {
            // Transfer NFT to winner
            IERC721(listing.assetContract).transferFrom(
                address(this), 
                winningOffer.offeror, 
                listing.tokenId
            );
            
            // Skip payment transfer - proceeds are handled by settlement vault
            // The settlement vault will handle the second-price mechanics
            // uint256 totalPayment = winningOffer.pricePerToken * winningOffer.quantityWanted;
            // IERC20(listing.currency).transfer(listing.tokenOwner, totalPayment);
            
            emit NewSale(
                listingId,
                listing.assetContract,
                listing.tokenOwner,
                winningOffer.offeror,
                winningOffer.quantityWanted,
                winningOffer.pricePerToken * winningOffer.quantityWanted
            );
        }
        
        // Refund losing bidders
        address[] memory bidders = _bidders[listingId];
        for (uint256 i = 0; i < bidders.length; i++) {
            address bidder = bidders[i];
            if (bidder != winningOffer.offeror) {
                Offer memory bid = _offers[listingId][bidder];
                if (bid.offeror != address(0)) {
                    uint256 refundAmount = bid.pricePerToken * bid.quantityWanted;
                    IERC20(listing.currency).transfer(bidder, refundAmount);
                }
            }
        }
        
        emit AuctionClosed(listingId, msg.sender, false, listing.tokenOwner, winningOffer.offeror);
    }
    
    function winningBid(uint256 listingId) external view override returns (
        address bidder,
        address currency,
        uint256 bidAmount
    ) {
        Offer memory bid = _winningBids[listingId];
        return (bid.offeror, bid.currency, bid.pricePerToken * bid.quantityWanted);
    }
    
    function listings(uint256 listingId) external view override returns (Listing memory) {
        return _listings[listingId];
    }
    
    function offers(uint256 listingId, address offeror) external view override returns (Offer memory) {
        return _offers[listingId][offeror];
    }
    
    // Helper function to get all bidders for testing
    function getBidders(uint256 listingId) external view returns (address[] memory) {
        return _bidders[listingId];
    }
    
    // Helper function to simulate settlement vault receiving proceeds
    function transferProceedsToVault(uint256 listingId, address vault) external {
        Listing memory listing = _listings[listingId];
        Offer memory winningOffer = _winningBids[listingId];

        if (winningOffer.offeror != address(0)) {
            uint256 totalPayment = winningOffer.pricePerToken * winningOffer.quantityWanted;
            // Transfer from this contract to settlement vault (proceeds already collected in offer)
            IERC20(listing.currency).transfer(vault, totalPayment);
        }
    }

    function getSecondHighestBid(uint256 listingId) external view returns (uint256) {
        address[] memory bidders = _bidders[listingId];
        if (bidders.length < 2) return 0; // No second bid

        uint256 max = 0;
        uint256 secondMax = 0;
        for (uint256 i = 0; i < bidders.length; i++) {
            uint256 bidAmount = _offers[listingId][bidders[i]].pricePerToken * _offers[listingId][bidders[i]].quantityWanted;
            if (bidAmount > max) {
                secondMax = max;
                max = bidAmount;
            } else if (bidAmount > secondMax) {
                secondMax = bidAmount;
            }
        }
        return secondMax;
    }
}
