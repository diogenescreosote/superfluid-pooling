// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IMarketplace.sol";
import "./Escrow.sol";

/**
 * @title AuctionAdapter
 * @dev Adapter for creating auctions on external marketplaces (thirdweb V3)
 * Handles earnest money and auction creation with proper parameters
 */
contract AuctionAdapter is Ownable, ReentrancyGuard {
    /// @notice Marketplace contract (thirdweb V3)
    IMarketplace public immutable marketplace;
    
    /// @notice Escrow contract
    Escrow public immutable escrow;
    
    /// @notice USDC token for earnest money
    IERC20 public immutable usdc;
    
    /// @notice Settlement vault that will receive proceeds
    address public settlementVault;
    
    /// @notice Default auction duration (72 hours)
    uint256 public constant DEFAULT_DURATION = 72 hours;
    
    /// @notice Default time buffer (10 minutes)
    uint256 public constant TIME_BUFFER = 10 minutes;
    
    /// @notice Default minimum bid increment (5%)
    uint256 public constant MIN_BID_INCREMENT_BPS = 500; // 5%
    
    /// @notice Mapping of auction ID to NFT details
    mapping(uint256 => AuctionInfo) public auctions;
    
    /// @notice Mapping to prevent multiple auctions per NFT
    mapping(address => mapping(uint256 => bool)) public nftHasActiveAuction;
    
    struct AuctionInfo {
        address collection;
        uint256 tokenId;
        address initiator;
        uint256 earnestAmount;
        uint256 reservePrice;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }
    
    event AuctionCreated(
        uint256 indexed listingId,
        address indexed collection,
        uint256 indexed tokenId,
        address initiator,
        uint256 earnestAmount,
        uint256 reservePrice
    );
    
    event AuctionParametersUpdated(
        uint256 duration,
        uint256 timeBuffer,
        uint256 minBidIncrementBps
    );
    
    error NFTNotInEscrow();
    error NFTAlreadyInAuction();
    error InsufficientEarnest();
    error TransferFailed();
    error AuctionNotFound();
    error ZeroAddress();
    error InvalidParameters();
    
    /**
     * @dev Constructor
     * @param marketplace_ Marketplace contract address
     * @param escrow_ Escrow contract address
     * @param usdc_ USDC token address
     * @param settlementVault_ Settlement vault address
     */
    constructor(
        IMarketplace marketplace_,
        Escrow escrow_,
        IERC20 usdc_,
        address settlementVault_
    ) Ownable(msg.sender) {
        if (
            address(marketplace_) == address(0) ||
            address(escrow_) == address(0) ||
            address(usdc_) == address(0)
        ) {
            revert ZeroAddress();
        }
        
        marketplace = marketplace_;
        escrow = escrow_;
        usdc = usdc_;
        settlementVault = settlementVault_;
    }
    
    /**
     * @dev Start an auction for an NFT in escrow
     * @param collection NFT collection address
     * @param tokenId Token ID
     * @param earnestAmount Earnest money amount (becomes reserve price and opening bid)
     * @param duration Auction duration in seconds (0 for default)
     */
    function startAuction(
        address collection,
        uint256 tokenId,
        uint256 earnestAmount,
        uint256 duration
    ) external nonReentrant returns (uint256 listingId) {
        // Validate NFT is in escrow and not already in auction
        if (!escrow.holdsNFT(collection, tokenId)) revert NFTNotInEscrow();
        if (nftHasActiveAuction[collection][tokenId]) revert NFTAlreadyInAuction();
        if (earnestAmount == 0) revert InsufficientEarnest();
        
        // CRITICAL FIX: Require caller to burn shares upfront (proves buyout rights)
        // This prevents unauthorized auctions and fixes the share burning issue
        escrow.burnSharesForAuction(msg.sender, collection, tokenId);
        
        // Use default duration if not specified
        uint256 auctionDuration = duration == 0 ? DEFAULT_DURATION : duration;
        if (auctionDuration < 1 hours) revert InvalidParameters();
        
        // Transfer earnest money from initiator
        if (!usdc.transferFrom(msg.sender, address(this), earnestAmount)) {
            revert TransferFailed();
        }
        
        // Approve marketplace to handle the earnest money as first bid
        usdc.approve(address(marketplace), earnestAmount);
        
        // Transfer NFT from escrow to this contract
        IERC721(collection).transferFrom(address(escrow), address(this), tokenId);
        
        // Approve marketplace to transfer NFT
        IERC721(collection).approve(address(marketplace), tokenId);
        
        // Create listing parameters
        IMarketplace.ListingParameters memory params = IMarketplace.ListingParameters({
            assetContract: collection,
            tokenId: tokenId,
            startTime: block.timestamp,
            secondsUntilEndTime: auctionDuration,
            quantityToList: 1,
            currencyToAccept: address(usdc),
            reservePrice: earnestAmount,
            buyoutPrice: type(uint256).max, // No buyout price
            listingType: 1 // Auction
        });
        
        // Create listing on marketplace
        listingId = marketplace.createListing(params);
        
        // Make the earnest money the opening bid
        marketplace.offer(
            listingId,
            1, // quantity
            address(usdc),
            earnestAmount,
            block.timestamp + auctionDuration
        );
        
        // Store auction info
        auctions[listingId] = AuctionInfo({
            collection: collection,
            tokenId: tokenId,
            initiator: msg.sender,
            earnestAmount: earnestAmount,
            reservePrice: earnestAmount,
            startTime: block.timestamp,
            endTime: block.timestamp + auctionDuration,
            active: true
        });
        
        // Mark NFT as in auction (already marked in burnSharesForAuction, but keep for consistency)
        nftHasActiveAuction[collection][tokenId] = true;
        // Note: escrow.markNFTInAuction() not needed - already set in burnSharesForAuction()
        
        emit AuctionCreated(
            listingId,
            collection,
            tokenId,
            msg.sender,
            earnestAmount,
            earnestAmount
        );
    }
    
    /**
     * @dev Get auction information
     * @param listingId Marketplace listing ID
     * @return Auction information struct
     */
    function getAuctionInfo(uint256 listingId) external view returns (AuctionInfo memory) {
        return auctions[listingId];
    }
    
    /**
     * @dev Check if NFT has an active auction
     * @param collection NFT collection
     * @param tokenId Token ID
     * @return True if NFT has active auction
     */
    function hasActiveAuction(address collection, uint256 tokenId) external view returns (bool) {
        return nftHasActiveAuction[collection][tokenId];
    }
    
    /**
     * @dev Mark auction as completed (called by settlement vault)
     * @param listingId Marketplace listing ID
     */
    function markAuctionCompleted(uint256 listingId) external {
        if (msg.sender != settlementVault) revert(); // Only settlement vault can call
        
        AuctionInfo storage auction = auctions[listingId];
        if (!auction.active) revert AuctionNotFound();
        
        auction.active = false;
        nftHasActiveAuction[auction.collection][auction.tokenId] = false;
    }
    
    /**
     * @dev Get marketplace listing details
     * @param listingId Marketplace listing ID
     * @return Marketplace listing struct
     */
    function getMarketplaceListing(uint256 listingId) external view returns (IMarketplace.Listing memory) {
        return marketplace.listings(listingId);
    }
    
    /**
     * @dev Get winning bid details
     * @param listingId Marketplace listing ID
     * @return bidder Winning bidder address
     * @return currency Bid currency
     * @return bidAmount Winning bid amount
     */
    function getWinningBid(uint256 listingId) external view returns (
        address bidder,
        address currency,
        uint256 bidAmount
    ) {
        return marketplace.winningBid(listingId);
    }
    
    /**
     * @dev Set settlement vault address
     * @param settlementVault_ Settlement vault address
     */
    function setSettlementVault(address settlementVault_) external onlyOwner {
        if (settlementVault_ == address(0)) revert ZeroAddress();
        settlementVault = settlementVault_;
    }
    
    /**
     * @dev Emergency function to rescue tokens
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescueToken(IERC20 token, uint256 amount) external onlyOwner {
        if (!token.transfer(owner(), amount)) revert TransferFailed();
    }
}

