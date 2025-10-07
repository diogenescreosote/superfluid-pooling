// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IMarketplace.sol";
import "./Escrow.sol";
import "./AuctionAdapter.sol";

// Interface for accessing mock marketplace second-price logic
interface IMarketplaceExtended is IMarketplace {
    function getSecondHighestBid(uint256 listingId) external view returns (uint256);
}

/**
 * @title SettlementVault
 * @dev Handles second-price auction settlement and proceeds routing
 * Implements second-price semantics by rebating difference to winner
 */
contract SettlementVault is Ownable, ReentrancyGuard {
    /// @notice Marketplace contract
    IMarketplace public immutable marketplace;
    
    /// @notice Escrow contract
    Escrow public immutable escrow;
    
    /// @notice Auction adapter
    AuctionAdapter public immutable auctionAdapter;
    
    /// @notice USDC token
    IERC20 public immutable usdc;
    
    /// @notice Mapping to track settled auctions
    mapping(uint256 => bool) public settledAuctions;
    
    /// @notice Mapping to track received proceeds per auction (FIX #5)
    mapping(uint256 => uint256) public auctionProceeds;
    
    /// @notice Nonce to prevent proceeds mixing across auctions
    uint256 private lastRecordedBalance;
    
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed collection,
        uint256 indexed tokenId,
        address winner,
        uint256 highestBid,
        uint256 clearingPrice,
        uint256 rebateAmount
    );
    
    event ProceedsReceived(uint256 indexed auctionId, uint256 amount);
    
    error AuctionAlreadySettled();
    error AuctionNotFound();
    error NoProceeds();
    error TransferFailed();
    error InvalidClearingPrice();
    error ZeroAddress();
    
    /**
     * @dev Constructor
     * @param marketplace_ Marketplace contract
     * @param escrow_ Escrow contract
     * @param auctionAdapter_ Auction adapter contract
     * @param usdc_ USDC token
     */
    constructor(
        IMarketplace marketplace_,
        Escrow escrow_,
        AuctionAdapter auctionAdapter_,
        IERC20 usdc_
    ) Ownable(msg.sender) {
        if (
            address(marketplace_) == address(0) ||
            address(escrow_) == address(0) ||
            address(auctionAdapter_) == address(0) ||
            address(usdc_) == address(0)
        ) {
            revert ZeroAddress();
        }
        
        marketplace = marketplace_;
        escrow = escrow_;
        auctionAdapter = auctionAdapter_;
        usdc = usdc_;
    }
    
    /**
     * @dev Receive auction proceeds from marketplace
     * Called after marketplace transfers USDC to this contract
     * @param auctionId Auction/listing ID
     */
    function receiveProceeds(uint256 auctionId) external payable {
        // FIX #5: Track per-auction proceeds accurately
        // Calculate only the NEW proceeds since last call
        uint256 currentBalance = usdc.balanceOf(address(this));
        uint256 newProceeds = currentBalance - lastRecordedBalance;
        
        auctionProceeds[auctionId] += newProceeds;
        lastRecordedBalance = currentBalance;
        
        emit ProceedsReceived(auctionId, newProceeds);
    }
    
    /**
     * @dev Settle an auction with second-price mechanics
     * @param auctionId Marketplace listing ID
     */
    function settle(uint256 auctionId) external nonReentrant {
        if (settledAuctions[auctionId]) revert AuctionAlreadySettled();
        
        // Get marketplace listing details to extract NFT info
        IMarketplace.Listing memory listing = marketplace.listings(auctionId);
        if (listing.assetContract == address(0)) revert AuctionNotFound();
        
        // Get winning bid
        (address winner, address currency, uint256 highestBid) = marketplace.winningBid(auctionId);
        
        // Calculate clearing price (second-price logic)
        uint256 clearingPrice = _calculateClearingPrice(auctionId, listing.reservePrice, highestBid);
        
        // FIX #5: Use per-auction proceeds tracking instead of total balance
        uint256 proceedsReceived = auctionProceeds[auctionId];
        if (proceedsReceived == 0) revert NoProceeds();
        
        // Calculate rebate amount
        uint256 rebateAmount = 0;
        if (proceedsReceived > clearingPrice) {
            rebateAmount = proceedsReceived - clearingPrice;
            
            // Send rebate to winner
            if (rebateAmount > 0 && winner != address(0)) {
                if (!usdc.transfer(winner, rebateAmount)) revert TransferFailed();
            }
        }
        
        // Send clearing price to escrow
        if (clearingPrice > 0) {
            if (!usdc.transfer(address(escrow), clearingPrice)) revert TransferFailed();
        }
        
        // Mark auction as settled and clear proceeds tracking
        settledAuctions[auctionId] = true;
        auctionProceeds[auctionId] = 0; // Clear claimed proceeds
        lastRecordedBalance = usdc.balanceOf(address(this)); // Update for next auction
        
        // Notify escrow of settlement
        escrow.onAuctionSettled(
            listing.assetContract,
            listing.tokenId,
            clearingPrice,
            winner
        );
        
        emit AuctionSettled(
            auctionId,
            listing.assetContract,
            listing.tokenId,
            winner,
            highestBid,
            clearingPrice,
            rebateAmount
        );
    }
    
    /**
     * @dev Calculate clearing price using second-price auction mechanics
     * @param auctionId Auction ID
     * @param reservePrice Reserve price
     * @param highestBid Highest bid amount
     * @return Clearing price (max of reserve and second highest bid)
     */
    function _calculateClearingPrice(
        uint256 auctionId,
        uint256 reservePrice,
        uint256 highestBid
    ) internal view returns (uint256) {
        // Get second highest bid from marketplace
        uint256 secondHighest = IMarketplaceExtended(address(marketplace)).getSecondHighestBid(auctionId);

        // Clearing price is the maximum of reserve price and second highest bid
        uint256 clearing = secondHighest > reservePrice ? secondHighest : reservePrice;

        // Ensure clearing price doesn't exceed highest bid
        return clearing > highestBid ? highestBid : clearing;
    }
    
    /**
     * @dev Get settlement details for an auction
     * @param auctionId Auction ID
     * @return settled Whether auction is settled
     * @return proceeds Proceeds received
     */
    function getSettlementInfo(uint256 auctionId) external view returns (
        bool settled,
        uint256 proceeds
    ) {
        settled = settledAuctions[auctionId];
        proceeds = auctionProceeds[auctionId];
    }
    
    /**
     * @dev Check if auction is settled
     * @param auctionId Auction ID
     * @return True if settled
     */
    function isSettled(uint256 auctionId) external view returns (bool) {
        return settledAuctions[auctionId];
    }
    
    /**
     * @dev Emergency function to rescue tokens
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueToken(IERC20 token, uint256 amount) external onlyOwner {
        if (!token.transfer(owner(), amount)) revert TransferFailed();
    }
    
    /**
     * @dev Emergency settlement function (owner only)
     * @param auctionId Auction ID
     * @param clearingPrice Manual clearing price
     * @param winner Winner address
     */
    function emergencySettle(
        uint256 auctionId,
        uint256 clearingPrice,
        address winner
    ) external onlyOwner nonReentrant {
        if (settledAuctions[auctionId]) revert AuctionAlreadySettled();
        
        IMarketplace.Listing memory listing = marketplace.listings(auctionId);
        if (listing.assetContract == address(0)) revert AuctionNotFound();
        
        uint256 balance = usdc.balanceOf(address(this));
        
        // Send clearing price to escrow
        if (clearingPrice > 0 && balance >= clearingPrice) {
            if (!usdc.transfer(address(escrow), clearingPrice)) revert TransferFailed();
        }
        
        // Send remainder to winner if any
        uint256 remainder = balance > clearingPrice ? balance - clearingPrice : 0;
        if (remainder > 0 && winner != address(0)) {
            if (!usdc.transfer(winner, remainder)) revert TransferFailed();
        }
        
        settledAuctions[auctionId] = true;
        
        escrow.onAuctionSettled(
            listing.assetContract,
            listing.tokenId,
            clearingPrice,
            winner
        );
        
        emit AuctionSettled(
            auctionId,
            listing.assetContract,
            listing.tokenId,
            winner,
            balance,
            clearingPrice,
            remainder
        );
    }
}


