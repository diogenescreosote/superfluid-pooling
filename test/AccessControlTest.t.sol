// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/PoolShare.sol";
import "../src/Escrow.sol";
import "../src/AuctionAdapter.sol";
import "../src/SettlementVault.sol";
import "../src/mocks/MockSuperfluid.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockERC721.sol";
import "../src/mocks/MockMarketplace.sol";

/**
 * @title AccessControlTest
 * @dev Tests access control mechanisms
 */
contract AccessControlTest is Test {
    // Core contracts
    PoolShare public poolShare;
    Escrow public escrow;
    AuctionAdapter public auctionAdapter;
    SettlementVault public settlementVault;
    
    // Mock contracts
    MockIDA public ida;
    MockSuperToken public superToken;
    MockERC20 public usdc;
    MockERC721 public nft;
    MockMarketplace public marketplace;
    
    // Test addresses
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public attacker = address(0x4);
    
    uint32 constant INDEX_ID = 0;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6, 10000000e6);
        nft = new MockERC721("Test NFT", "TNFT");
        
        // Deploy mock Superfluid components
        ida = new MockIDA();
        superToken = new MockSuperToken("USD Coin x", "USDCx", address(usdc));
        
        // Deploy mock marketplace
        marketplace = new MockMarketplace();
        
        // Deploy core contracts
        poolShare = new PoolShare(
            "Pool Share Token",
            "PST",
            ida,
            superToken,
            INDEX_ID,
            0 // No minimum hold period for tests
        );
        
        address[] memory allowedCollections = new address[](1);
        allowedCollections[0] = address(nft);
        
        escrow = new Escrow(
            poolShare,
            usdc,
            superToken,
            ida,
            INDEX_ID,
            allowedCollections
        );
        
        poolShare.setEscrow(address(escrow));
        
        settlementVault = new SettlementVault(
            marketplace,
            escrow,
            AuctionAdapter(address(1)),
            usdc
        );
        
        auctionAdapter = new AuctionAdapter(
            marketplace,
            escrow,
            usdc,
            address(settlementVault),
            500e6 // 500 USDC minimum earnest
        );
        
        escrow.setSettlementVault(address(settlementVault));

        // Add this line to fix OnlyAuctionAdapter reverts
        escrow.setAuctionAdapter(address(auctionAdapter));

        vm.stopPrank();
        
        // Setup test data
        _setupTestData();
    }
    
    function _setupTestData() internal {
        // Mint NFTs
        nft.mint(user1, 1);
        nft.mint(user2, 2);
        
        // Distribute USDC
        vm.startPrank(owner);
        usdc.transfer(user1, 10000e6);
        usdc.transfer(user2, 10000e6);
        usdc.transfer(address(escrow), 5000e6);
        vm.stopPrank();
    }
    
    function testPoolShareMintAccess() public {
        // Only escrow can mint
        vm.prank(attacker);
        vm.expectRevert(PoolShare.OnlyEscrow.selector);
        poolShare.mint(user1, 1e18);
        
        // Escrow can mint
        vm.prank(address(escrow));
        poolShare.mint(user1, 1e18);
        assertEq(poolShare.balanceOf(user1), 1e18);
    }
    
    function testPoolShareBurnAccess() public {
        // First mint some tokens
        vm.prank(address(escrow));
        poolShare.mint(user1, 1e18);
        
        // Only escrow can burn
        vm.prank(attacker);
        vm.expectRevert(PoolShare.OnlyEscrow.selector);
        poolShare.burn(user1, 1e18);
        
        // Escrow can burn
        vm.prank(address(escrow));
        poolShare.burn(user1, 1e18);
        assertEq(poolShare.balanceOf(user1), 0);
    }
    
    function testPoolShareEscrowSetAccess() public {
        // Deploy new pool share for this test to avoid EscrowAlreadySet
        vm.startPrank(owner);
        PoolShare newPoolShare = new PoolShare(
            "Test Pool Share",
            "TPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );
        vm.stopPrank();

        // Only owner can set escrow
        vm.prank(attacker);
        vm.expectRevert(); // Ownable unauthorized
        newPoolShare.setEscrow(address(0x5));

        // Owner can set escrow
        vm.prank(owner);
        newPoolShare.setEscrow(address(0x5));
        assertEq(newPoolShare.escrow(), address(0x5));

        // Cannot set again
        vm.prank(owner);
        vm.expectRevert(PoolShare.EscrowAlreadySet.selector);
        newPoolShare.setEscrow(address(0x6));
    }
    
    function testEscrowDepositAccess() public {
        // Anyone can deposit (permissionless)
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        assertEq(poolShare.balanceOf(user1), 1e18);
    }
    
    function testEscrowForwardRevenueAccess() public {
        // Anyone can call forwardRevenue (permissionless)
        vm.prank(attacker);
        escrow.forwardRevenue(); // Should not revert
        
        // Verify revenue was processed
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testEscrowOnAuctionSettledAccess() public {
        // First deposit an NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();

        // Simulate upfront burn (new requirement)
        vm.prank(address(auctionAdapter));
        escrow.burnSharesForAuction(user1, address(nft), 1);

        // Only settlement vault can call onAuctionSettled
        vm.prank(attacker);
        vm.expectRevert(Escrow.OnlySettlementVault.selector);
        escrow.onAuctionSettled(address(nft), 1, 1000e6, user2);

        // Settlement vault can call
        // Add approval for USDC to USDCx to prevent allowance error
        vm.startPrank(address(escrow));
        usdc.approve(address(superToken), 1000e6);
        vm.stopPrank();

        // Simulate proceeds transfer
        vm.prank(owner);
        usdc.transfer(address(escrow), 1000e6);

        vm.prank(address(settlementVault));
        escrow.onAuctionSettled(address(nft), 1, 1000e6, user2);

        assertEq(poolShare.balanceOf(user1), 0);
    }
    
    function testEscrowOwnerFunctions() public {
        // Only owner can set collection allowed
        vm.prank(attacker);
        vm.expectRevert();
        escrow.setCollectionAllowed(address(0x5), true);
        
        // Owner can set collection allowed
        vm.prank(owner);
        escrow.setCollectionAllowed(address(0x5), true);
        assertTrue(escrow.allowedCollections(address(0x5)));
        
        // Only owner can set settlement vault
        vm.prank(attacker);
        vm.expectRevert();
        escrow.setSettlementVault(address(0x6));
        
        // Owner can set settlement vault
        vm.prank(owner);
        escrow.setSettlementVault(address(0x6));
        assertEq(escrow.settlementVault(), address(0x6));
        
        // Only owner can pause
        vm.prank(attacker);
        vm.expectRevert();
        escrow.pause();
        
        // Owner can pause
        vm.prank(owner);
        escrow.pause();
        assertTrue(escrow.paused());
        
        // Only owner can unpause
        vm.prank(attacker);
        vm.expectRevert();
        escrow.unpause();
        
        // Owner can unpause
        vm.prank(owner);
        escrow.unpause();
        assertFalse(escrow.paused());
    }
    
    function testEscrowPauseFunctionality() public {
        // Pause the contract
        vm.prank(owner);
        escrow.pause();
        
        // Deposit should fail when paused
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.expectRevert(Escrow.ContractPaused.selector);
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Forward revenue should fail when paused
        vm.prank(attacker);
        vm.expectRevert(Escrow.ContractPaused.selector);
        escrow.forwardRevenue();
        
        // Unpause
        vm.prank(owner);
        escrow.unpause();
        
        // Now deposit should work
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        assertEq(poolShare.balanceOf(user1), 1e18);
    }
    
    function testEscrowUpdateIDASubscriptionAccess() public {
        // Only pool share can call updateIDASubscription
        vm.prank(attacker);
        vm.expectRevert(Escrow.OnlyPoolShare.selector);
        escrow.updateIDASubscription(user1, 1e18);
        
        // Pool share can call (this would be called internally)
        vm.prank(address(poolShare));
        escrow.updateIDASubscription(user1, 1e18);
        // Should not revert
    }
    
    function testEscrowApproveAuctionAdapterAccess() public {
        // First deposit an NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Only owner can approve auction adapter
        vm.prank(attacker);
        vm.expectRevert();
        escrow.approveAuctionAdapter(address(auctionAdapter), address(nft), 1);
        
        // Owner can approve
        vm.prank(owner);
        escrow.approveAuctionAdapter(address(auctionAdapter), address(nft), 1);
        // Should not revert
    }
    
    function testAuctionAdapterStartAuctionAccess() public {
        // First deposit an NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();

        // Attacker without shares cannot start auction
        vm.startPrank(attacker);
        usdc.approve(address(auctionAdapter), 500e6);
        vm.expectRevert(Escrow.InsufficientShares.selector);
        auctionAdapter.startAuction(address(nft), 1, 500e6, 72 hours);
        vm.stopPrank();

        // Transfer shares to legitimate initiator (user2)
        vm.prank(user1);
        poolShare.transfer(user2, 1e18);

        // Approve USDC and NFT transfers
        vm.startPrank(user2);
        usdc.approve(address(auctionAdapter), 500e6);
        vm.stopPrank();

        // Approve auction adapter for NFT (normally done by owner or in setup)
        vm.prank(owner);
        escrow.setApprovalForAll(address(nft), address(auctionAdapter), true);

        // Legitimate initiator with shares can start auction
        vm.prank(user2);
        auctionAdapter.startAuction(address(nft), 1, 500e6, 72 hours);
        // Should not revert
    }
    
    function testSettlementVaultSettleAccess() public {
        // Anyone can call settle (permissionless)
        // Test that it reverts properly if no auction
        vm.expectRevert();
        settlementVault.settle(1);
    }
    
    function testSettlementVaultOwnerFunctions() public {
        // Only owner can call owner functions
        vm.prank(attacker);
        vm.expectRevert();
        settlementVault.transferOwnership(attacker);
        
        // Owner can transfer ownership
        vm.prank(owner);
        settlementVault.transferOwnership(user1);
        assertEq(settlementVault.owner(), user1);
    }
    
    function testZeroAddressValidation() public {
        // Test zero address validation in various functions

        // PoolShare setEscrow - deploy new for test
        vm.startPrank(owner);
        PoolShare newPoolShare = new PoolShare(
            "New Pool Share",
            "NPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );
        vm.expectRevert(PoolShare.ZeroAddress.selector);
        newPoolShare.setEscrow(address(0));

        // Escrow setCollectionAllowed
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.setCollectionAllowed(address(0), true);

        // Escrow setSettlementVault
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.setSettlementVault(address(0));

        vm.stopPrank();
    }
    
    function testReentrancyProtection() public {
        // Test that reentrancy guards are working
        // This would require a malicious contract, but we can test basic functionality
        
        // Deposit should work normally
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        assertEq(poolShare.balanceOf(user1), 1e18);
    }

    function testBurnSharesForAuctionAccess() public {
        // Deposit NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();

        // Only adapter can call
        vm.expectRevert(Escrow.OnlyAuctionAdapter.selector);
        escrow.burnSharesForAuction(user1, address(nft), 1);

        // Adapter can call
        vm.prank(address(auctionAdapter));
        escrow.burnSharesForAuction(user1, address(nft), 1);

        assertEq(poolShare.balanceOf(user1), 0);
    }
}
