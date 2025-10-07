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
    
    /// @notice Minimum earnest money required to start an auction
    uint256 public immutable minEarnest;
    
    event AuctionCreated(uint256 indexed listingId, address indexed collection, uint256 indexed tokenId, address initiator, uint256 earnestAmount);

    error NFTNotInEscrow();
    error InsufficientEarnest();
    error TransferFailed();
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
        address settlementVault_,
        uint256 minEarnest_
    ) Ownable(msg.sender) {
        if (address(marketplace_) == address(0) || address(escrow_) == address(0) || address(usdc_) == address(0)) {
            revert ZeroAddress();
        }
        
        marketplace = marketplace_;
        escrow = escrow_;
        usdc = usdc_;
        settlementVault = settlementVault_;
        minEarnest = minEarnest_;
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
        if (!escrow.holdsNFT(collection, tokenId)) revert NFTNotInEscrow();
        if (earnestAmount < minEarnest) revert InsufficientEarnest();

        escrow.burnSharesForAuction(msg.sender, collection, tokenId);

        uint256 auctionDuration = duration == 0 ? DEFAULT_DURATION : duration;
        if (auctionDuration < 1 hours) revert InvalidParameters();

        if (!usdc.transferFrom(msg.sender, address(this), earnestAmount)) {
            revert TransferFailed();
        }

        usdc.approve(address(marketplace), earnestAmount);

        IERC721(collection).transferFrom(address(escrow), address(this), tokenId);
        IERC721(collection).approve(address(marketplace), tokenId);

        IMarketplace.ListingParameters memory params = IMarketplace.ListingParameters({
            assetContract: collection,
            tokenId: tokenId,
            startTime: block.timestamp,
            secondsUntilEndTime: auctionDuration,
            quantityToList: 1,
            currencyToAccept: address(usdc),
            reservePrice: earnestAmount,
            buyoutPrice: type(uint256).max,
            listingType: 1
        });

        listingId = marketplace.createListing(params);

        marketplace.offer(
            listingId,
            1,
            address(usdc),
            earnestAmount,
            block.timestamp + auctionDuration
        );

        emit AuctionCreated(listingId, collection, tokenId, msg.sender, earnestAmount);
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

