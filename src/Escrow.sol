// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ISuperfluid.sol";
import "./PoolShare.sol";

/**
 * @title Escrow
 * @dev Custody contract for NFTs with Superfluid IDA revenue distribution
 * Holds NFTs, mints/burns pool shares, and distributes revenue via Superfluid
 */
contract Escrow is ERC721Holder, Ownable, ReentrancyGuard {
    /// @notice Pool share token
    PoolShare public immutable poolShare;
    
    /// @notice USDC token
    IERC20 public immutable usdc;
    
    /// @notice USDCx SuperToken
    ISuperToken public immutable usdcx;
    
    /// @notice Superfluid IDA contract
    IInstantDistributionAgreementV1 public immutable ida;
    
    /// @notice Index ID for IDA distributions
    uint32 public immutable indexId;
    
    /// @notice Amount of pool shares per NFT (1e18)
    uint256 public constant SHARES_PER_NFT = 1e18;
    
    /// @notice Mapping of allowed NFT collections
    mapping(address => bool) public allowedCollections;
    
    /// @notice Mapping to track NFT depositors: collection => tokenId => depositor
    mapping(address => mapping(uint256 => address)) public depositors;
    
    /// @notice Settlement vault address (can call onAuctionSettled)
    address public settlementVault;
    
    /// @notice Auction adapter address (can call burnSharesForAuction)
    address public auctionAdapter;
    
    /// @notice Total NFTs held
    uint256 public totalNFTs;
    
    /// @notice Circuit breaker state
    bool public paused;
    
    event CollectionAllowed(address indexed collection, bool allowed);
    event NFTDeposited(address indexed collection, uint256 indexed tokenId, address indexed depositor);
    event RevenueDistributed(uint256 amount, string source);
    event AuctionProceedsDistributed(address indexed collection, uint256 indexed tokenId, uint256 clearingPrice);
    event SettlementVaultSet(address indexed settlementVault);
    event AuctionAdapterSet(address indexed auctionAdapter);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    
    error CollectionNotAllowed();
    error NFTNotOwned();
    error OnlySettlementVault();
    error OnlyAuctionAdapter();
    error OnlyPoolShare();
    error InvalidDepositor();
    error ZeroAddress();
    error TransferFailed();
    error InvariantViolation();
    error ContractPaused();
    error InsufficientShares();
    
    /**
     * @dev Constructor
     * @param poolShare_ Pool share token address
     * @param usdc_ USDC token address
     * @param usdcx_ USDCx SuperToken address
     * @param ida_ Superfluid IDA contract
     * @param indexId_ Index ID for IDA distributions
     * @param allowedCollections_ Initial allowed collections
     */
    constructor(
        PoolShare poolShare_,
        IERC20 usdc_,
        ISuperToken usdcx_,
        IInstantDistributionAgreementV1 ida_,
        uint32 indexId_,
        address[] memory allowedCollections_
    ) Ownable(msg.sender) {
        if (
            address(poolShare_) == address(0) ||
            address(usdc_) == address(0) ||
            address(usdcx_) == address(0) ||
            address(ida_) == address(0)
        ) {
            revert ZeroAddress();
        }
        
        poolShare = poolShare_;
        usdc = usdc_;
        usdcx = usdcx_;
        ida = ida_;
        indexId = indexId_;
        
        // Create IDA index
        ida.createIndex(usdcx_, indexId_, "");

        // Set infinite approval for IDA to handle distributions
        usdcx.approve(address(ida), type(uint256).max);
        
        // Allow initial collections
        for (uint256 i = 0; i < allowedCollections_.length; i++) {
            if (allowedCollections_[i] != address(0)) {
                allowedCollections[allowedCollections_[i]] = true;
                emit CollectionAllowed(allowedCollections_[i], true);
            }
        }
    }
    
    /**
     * @dev Set settlement vault address
     * @param settlementVault_ Settlement vault address
     */
    function setSettlementVault(address settlementVault_) external onlyOwner {
        if (settlementVault_ == address(0)) revert ZeroAddress();
        settlementVault = settlementVault_;
        emit SettlementVaultSet(settlementVault_);
    }
    
    /**
     * @dev Set auction adapter address
     * @param auctionAdapter_ Auction adapter address
     */
    function setAuctionAdapter(address auctionAdapter_) external onlyOwner {
        if (auctionAdapter_ == address(0)) revert ZeroAddress();
        auctionAdapter = auctionAdapter_;
        emit AuctionAdapterSet(auctionAdapter_);
    }
    
    /**
     * @dev Allow or disallow an NFT collection
     * @param collection Collection address
     * @param allowed Whether to allow the collection
     */
    function setCollectionAllowed(address collection, bool allowed) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        allowedCollections[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }
    
    /**
     * @dev Deposit NFTs and mint pool shares
     * @param collection NFT collection address
     * @param tokenIds Array of token IDs to deposit
     */
    function deposit(address collection, uint256[] calldata tokenIds) external nonReentrant {
        if (paused) revert ContractPaused();
        if (!allowedCollections[collection]) revert CollectionNotAllowed();

        IERC721 nft = IERC721(collection);
        uint256 numTokens = tokenIds.length;

        for (uint256 i = 0; i < numTokens; ) {
            uint256 tokenId = tokenIds[i];
            nft.safeTransferFrom(msg.sender, address(this), tokenId);
            depositors[collection][tokenId] = msg.sender;
            emit NFTDeposited(collection, tokenId, msg.sender);
            unchecked { i++; }
        }

        unchecked { totalNFTs += numTokens; }
        uint256 sharesToMint = numTokens * SHARES_PER_NFT;
        poolShare.mint(msg.sender, sharesToMint);

        if (poolShare.totalSupply() != totalNFTs * SHARES_PER_NFT) revert InvariantViolation();
    }
    
    /**
     * @dev Forward revenue from operations (leasing, etc.)
     * Converts USDC to USDCx and distributes via IDA
     */
    function forwardRevenue() external nonReentrant {
        if (paused) revert ContractPaused();
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance == 0) return;
        
        // FIX #6: Check if approve succeeds
        bool approved = usdc.approve(address(usdcx), usdcBalance);
        require(approved, "USDC approval failed");
        
        // FIX #6: Verify upgrade worked by checking balance increase
        uint256 usdcxBefore = usdcx.balanceOf(address(this));
        try usdcx.upgrade(usdcBalance) {
            uint256 usdcxAfter = usdcx.balanceOf(address(this));
            require(usdcxAfter >= usdcxBefore + usdcBalance, "USDCx upgrade failed");
        } catch {
            // If upgrade fails, USDC stays in contract for manual recovery
            emit RevenueDistributed(0, "upgrade_failed");
            return;
        }
        
        // FIX #6: Try distribute with error handling
        try ida.distribute(usdcx, indexId, usdcBalance, "") {
            emit RevenueDistributed(usdcBalance, "operations");
        } catch {
            // Distribution failed - USDCx stuck, needs manual intervention
            emit RevenueDistributed(0, "distribute_failed");
        }
    }
    
    /**
     * @dev Burn shares for auction initiation (called by AuctionAdapter)
     * This is called BEFORE auction starts to prove buyout rights
     * @param initiator Address initiating the auction
     * @param collection NFT collection
     * @param tokenId Token ID
     */
    function burnSharesForAuction(
        address initiator,
        address collection,
        uint256 tokenId
    ) external nonReentrant {
        if (msg.sender != auctionAdapter) revert OnlyAuctionAdapter();
        if (depositors[collection][tokenId] == address(0)) revert NFTNotOwned();

        if (poolShare.balanceOf(initiator) < SHARES_PER_NFT) revert InsufficientShares();

        poolShare.burn(initiator, SHARES_PER_NFT);
        totalNFTs -= 1;

        if (poolShare.totalSupply() != totalNFTs * SHARES_PER_NFT) revert InvariantViolation();
    }
    
    /**
     * @dev Handle auction settlement (called by SettlementVault)
     * @param collection NFT collection
     * @param tokenId Token ID
     * @param clearingPrice Final clearing price
     * @param winner Auction winner
     */
    function onAuctionSettled(
        address collection,
        uint256 tokenId,
        uint256 clearingPrice,
        address winner
    ) external nonReentrant {
        if (msg.sender != settlementVault) revert OnlySettlementVault();
        
        address depositor = depositors[collection][tokenId];
        if (depositor == address(0)) revert InvalidDepositor();
        
        delete depositors[collection][tokenId];

        if (clearingPrice > 0) {
            // FIX #6: Same error handling for auction settlements
            bool approved = usdc.approve(address(usdcx), clearingPrice);
            require(approved, "USDC approval failed");
            
            uint256 usdcxBefore = usdcx.balanceOf(address(this));
            try usdcx.upgrade(clearingPrice) {
                uint256 usdcxAfter = usdcx.balanceOf(address(this));
                require(usdcxAfter >= usdcxBefore + clearingPrice, "USDCx upgrade failed");
                
                // Try to distribute
                try ida.distribute(usdcx, indexId, clearingPrice, "") {
                    emit AuctionProceedsDistributed(collection, tokenId, clearingPrice);
                } catch {
                    // Distribution failed but proceeds are converted to USDCx
                    emit AuctionProceedsDistributed(collection, tokenId, 0);
                }
            } catch {
                // Upgrade failed, USDC remains in contract
                emit AuctionProceedsDistributed(collection, tokenId, 0);
            }
        } else {
            emit AuctionProceedsDistributed(collection, tokenId, clearingPrice);
        }
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
     * @dev Get NFT inventory count
     * @return Total number of NFTs held
     */
    function getInventoryCount() external view returns (uint256) {
        return totalNFTs;
    }
    
    /**
     * @dev Check if NFT is held by this contract
     * @param collection NFT collection
     * @param tokenId Token ID
     * @return True if NFT is held
     */
    function holdsNFT(address collection, uint256 tokenId) external view returns (bool) {
        return depositors[collection][tokenId] != address(0);
    }
    
    /**
     * @dev Get depositor of an NFT
     * @param collection NFT collection
     * @param tokenId Token ID
     * @return Depositor address
     */
    function getDepositor(address collection, uint256 tokenId) external view returns (address) {
        return depositors[collection][tokenId];
    }
    
    /**
     * @dev Update IDA subscription for an account (called by PoolShare)
     * @param account Account to update
     * @param units New units amount
     */
    function updateIDASubscription(address account, uint128 units) external {
        // Only pool share can call this
        if (msg.sender != address(poolShare)) {
            revert OnlyPoolShare();
        }
        
        ida.updateSubscription(
            usdcx,
            indexId,
            account,
            units,
            ""
        );
    }
    
    /**
     * @dev Approve auction adapter for NFT transfer (called by owner)
     * @param auctionAdapter_ Auction adapter address
     * @param collection NFT collection
     * @param tokenId Token ID
     */
    function approveAuctionAdapter(
        address auctionAdapter_,
        address collection,
        uint256 tokenId
    ) external onlyOwner {
        require(depositors[collection][tokenId] != address(0), "NFT not in escrow");
        
        IERC721(collection).approve(auctionAdapter_, tokenId);
    }
    
    /**
     * @dev Set approval for all NFTs in a collection to an operator
     * @param collection NFT collection
     * @param operator Operator address (e.g., AuctionAdapter)
     * @param approved Whether to approve or revoke
     */
    function setApprovalForAll(
        address collection,
        address operator,
        bool approved
    ) external onlyOwner {
        IERC721(collection).setApprovalForAll(operator, approved);
    }
    
    /**
     * @dev Batch approve auction adapter for multiple NFTs
     * @param auctionAdapter_ Auction adapter address
     * @param collection NFT collection
     * @param tokenIds Array of token IDs
     */
    function batchApproveAuctionAdapter(
        address auctionAdapter_,
        address collection,
        uint256[] calldata tokenIds
    ) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(depositors[collection][tokenId] != address(0), "NFT not in escrow");
            
            IERC721(collection).approve(auctionAdapter_, tokenId);
        }
    }
    
    /**
     * @dev Pause the contract (emergency function)
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
}

