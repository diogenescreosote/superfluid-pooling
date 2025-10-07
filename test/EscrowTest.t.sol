// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/Escrow.sol";
import "../src/PoolShare.sol";
import "../src/mocks/MockSuperfluid.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockERC721.sol";

contract EscrowTest is Test {
    Escrow public escrow;
    PoolShare public poolShare;
    MockIDA public ida;
    MockSuperToken public superToken;
    MockERC20 public usdc;
    MockERC721 public nft;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public settlementVault = address(0x4);
    address public auctionAdapter = address(0x5);
    
    uint32 constant INDEX_ID = 0;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6, 1000000e6);
        nft = new MockERC721("Test NFT", "TNFT");
        
        // Deploy mock Superfluid components
        ida = new MockIDA();
        superToken = new MockSuperToken("USD Coin x", "USDCx", address(usdc));
        
        // Deploy PoolShare
        poolShare = new PoolShare(
            "Pool Share Token",
            "PST",
            ida,
            superToken,
            INDEX_ID
        );
        
        // Deploy Escrow
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
        
        // Set escrow in pool share
        poolShare.setEscrow(address(escrow));
        
        // Set settlement vault
        escrow.setSettlementVault(settlementVault);
        
        // Set auction adapter
        escrow.setAuctionAdapter(auctionAdapter);
        
        vm.stopPrank();
        
        // Mint some NFTs to users
        nft.mint(user1, 1);
        nft.mint(user1, 2);
        nft.mint(user2, 3);
        
        // Give users some USDC
        vm.startPrank(owner);
        usdc.transfer(user1, 10000e6);
        usdc.transfer(user2, 10000e6);
        usdc.transfer(address(escrow), 5000e6); // For revenue distribution tests
        vm.stopPrank();
    }
    
    function testInitialState() public {
        assertEq(address(escrow.poolShare()), address(poolShare));
        assertEq(address(escrow.usdc()), address(usdc));
        assertEq(address(escrow.usdcx()), address(superToken));
        assertEq(address(escrow.ida()), address(ida));
        assertEq(escrow.indexId(), INDEX_ID);
        assertEq(escrow.totalNFTs(), 0);
        assertEq(escrow.settlementVault(), settlementVault);
        assertTrue(escrow.allowedCollections(address(nft)));
    }
    
    function testDepositSingleNFT() public {
        // Approve NFT transfer
        vm.prank(user1);
        nft.approve(address(escrow), 1);
        
        // Deposit NFT
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        
        vm.prank(user1);
        escrow.deposit(address(nft), tokenIds);
        
        // Check state
        assertEq(escrow.totalNFTs(), 1);
        assertEq(poolShare.balanceOf(user1), 1e18);
        assertEq(poolShare.totalSupply(), 1e18);
        assertEq(escrow.getDepositor(address(nft), 1), user1);
        assertTrue(escrow.holdsNFT(address(nft), 1));
        assertEq(nft.ownerOf(1), address(escrow));
    }
    
    function testDepositMultipleNFTs() public {
        // Approve NFT transfers
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        nft.approve(address(escrow), 2);
        
        // Deposit NFTs
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Check state
        assertEq(escrow.totalNFTs(), 2);
        assertEq(poolShare.balanceOf(user1), 2e18);
        assertEq(poolShare.totalSupply(), 2e18);
        assertEq(escrow.getDepositor(address(nft), 1), user1);
        assertEq(escrow.getDepositor(address(nft), 2), user1);
    }
    
    function testCannotDepositDisallowedCollection() public {
        // Deploy new NFT collection (not allowed)
        MockERC721 newNft = new MockERC721("New NFT", "NNFT");
        newNft.mint(user1, 1);
        
        vm.startPrank(user1);
        newNft.approve(address(escrow), 1);
        
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        
        vm.expectRevert(Escrow.CollectionNotAllowed.selector);
        escrow.deposit(address(newNft), tokenIds);
        
        vm.stopPrank();
    }
    
    function testForwardRevenue() public {
        // First deposit an NFT so there are pool share holders
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Check initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(address(escrow));
        assertGt(initialUsdcBalance, 0);
        
        // Approve SuperToken to spend USDC from escrow
        vm.prank(address(escrow));
        usdc.approve(address(superToken), initialUsdcBalance);
        
        // Approve MockIDA to spend SuperTokens from escrow
        vm.prank(address(escrow));
        superToken.approve(address(ida), initialUsdcBalance);
        
        // Forward revenue
        escrow.forwardRevenue();
        
        // Check that USDC was converted to USDCx and distributed
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertGt(superToken.balanceOf(address(ida)), 0);
    }
    
    function testOnAuctionSettled() public {
        // First deposit an NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Check initial state
        assertEq(escrow.totalNFTs(), 1);
        assertEq(poolShare.balanceOf(user1), 1e18);
        assertEq(poolShare.totalSupply(), 1e18);
        
        // CRITICAL FIX: Burn shares upfront (simulating auction start)
        vm.prank(auctionAdapter);
        escrow.burnSharesForAuction(user1, address(nft), 1);
        
        // Simulate auction settlement
        uint256 clearingPrice = 1000e6;
        vm.startPrank(owner);
        usdc.transfer(address(escrow), clearingPrice);
        vm.stopPrank();
        
        // Add approval for USDC to USDCx
        vm.prank(address(escrow));
        usdc.approve(address(superToken), clearingPrice);
        
        // Simulate marketplace transferring NFT to winner (in real flow, marketplace does this)
        vm.prank(address(escrow));
        nft.transferFrom(address(escrow), user2, 1);
        
        vm.prank(settlementVault);
        escrow.onAuctionSettled(address(nft), 1, clearingPrice, user2);
        
        // Check final state
        assertEq(escrow.totalNFTs(), 0);
        assertEq(poolShare.balanceOf(user1), 0);
        assertEq(poolShare.totalSupply(), 0);
        assertEq(escrow.getDepositor(address(nft), 1), address(0));
        assertFalse(escrow.holdsNFT(address(nft), 1));
        assertEq(nft.ownerOf(1), user2);
    }
    
    function testOnlySettlementVaultCanSettle() public {
        // First deposit an NFT
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        escrow.deposit(address(nft), tokenIds);
        vm.stopPrank();
        
        // Non-settlement vault should not be able to call onAuctionSettled
        vm.prank(user1);
        vm.expectRevert(Escrow.OnlySettlementVault.selector);
        escrow.onAuctionSettled(address(nft), 1, 1000e6, user2);
    }
    
    function testSetCollectionAllowed() public {
        MockERC721 newNft = new MockERC721("New NFT", "NNFT");
        
        // Initially not allowed
        assertFalse(escrow.allowedCollections(address(newNft)));
        
        // Owner can allow
        vm.prank(owner);
        escrow.setCollectionAllowed(address(newNft), true);
        assertTrue(escrow.allowedCollections(address(newNft)));
        
        // Owner can disallow
        vm.prank(owner);
        escrow.setCollectionAllowed(address(newNft), false);
        assertFalse(escrow.allowedCollections(address(newNft)));
    }
    
    function testCannotSetZeroAddressCollection() public {
        vm.prank(owner);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.setCollectionAllowed(address(0), true);
    }
    
    function testCannotSetZeroAddressSettlementVault() public {
        vm.prank(owner);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        escrow.setSettlementVault(address(0));
    }
    
    function testRescueToken() public {
        // Give escrow some extra USDC
        uint256 rescueAmount = 1000e6;
        vm.startPrank(owner);
        usdc.transfer(address(escrow), rescueAmount);
        vm.stopPrank();
        
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        
        vm.prank(owner);
        escrow.rescueToken(usdc, rescueAmount);
        
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + rescueAmount);
    }
    
    function testInvariantTotalSupplyEqualsInventory() public {
        // Deposit multiple NFTs from different users
        vm.startPrank(user1);
        nft.approve(address(escrow), 1);
        nft.approve(address(escrow), 2);
        uint256[] memory tokenIds1 = new uint256[](2);
        tokenIds1[0] = 1;
        tokenIds1[1] = 2;
        escrow.deposit(address(nft), tokenIds1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        nft.approve(address(escrow), 3);
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = 3;
        escrow.deposit(address(nft), tokenIds2);
        vm.stopPrank();
        
        // Check invariant: totalSupply == totalNFTs * SHARES_PER_NFT
        assertEq(poolShare.totalSupply(), escrow.totalNFTs() * escrow.SHARES_PER_NFT());
        assertEq(poolShare.totalSupply(), 3e18);
        assertEq(escrow.totalNFTs(), 3);
    }
}
