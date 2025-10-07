// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/PoolShare.sol";
import "../src/mocks/MockSuperfluid.sol";
import "../src/mocks/MockERC20.sol";

// Mock escrow for testing IDA functionality
contract MockEscrow {
    MockIDA public ida;
    ISuperToken public superToken;
    uint32 public indexId;
    
    constructor(MockIDA ida_, ISuperToken superToken_, uint32 indexId_) {
        ida = ida_;
        superToken = superToken_;
        indexId = indexId_;
    }
    
    function updateIDASubscription(address account, uint128 units) external {
        ida.updateSubscription(superToken, indexId, account, units, "");
    }
}

/**
 * @title IDASyncTest
 * @dev Tests IDA synchronization functionality
 */
contract IDASyncTest is Test {
    PoolShare public poolShare;
    MockIDA public ida;
    MockSuperToken public superToken;
    MockERC20 public usdc;
    MockEscrow public mockEscrow;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    
    uint32 constant INDEX_ID = 0;
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6, 1000000e6);
        
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
        
        // Deploy mock escrow
        mockEscrow = new MockEscrow(ida, superToken, INDEX_ID);
        
        // Set escrow
        poolShare.setEscrow(address(mockEscrow));
        
        vm.stopPrank();
        
        // Create IDA index - must be called by the publisher (mockEscrow)
        vm.prank(address(mockEscrow));
        ida.createIndex(superToken, INDEX_ID, "");
    }
    
    function testIDASyncOnMint() public {
        // Mint tokens to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 2e18);
        
        // Check IDA units
        assertEq(poolShare.getIDAUnits(user1), 2e18);
        assertEq(poolShare.getIDAUnits(user2), 0);
        
        // Verify IDA subscription exists
        (bool exist, , uint128 units, ) = ida.getSubscription(superToken, address(mockEscrow), INDEX_ID, user1);
        assertTrue(exist);
        assertEq(units, 2e18);
    }
    
    function testIDASyncOnBurn() public {
        // First mint tokens
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 2e18);
        
        // Burn half
        vm.prank(address(mockEscrow));
        poolShare.burn(user1, 1e18);
        
        // Check IDA units
        assertEq(poolShare.getIDAUnits(user1), 1e18);
        
        // Verify IDA subscription updated
        (bool exist, , uint128 units, ) = ida.getSubscription(superToken, address(mockEscrow), INDEX_ID, user1);
        assertTrue(exist);
        assertEq(units, 1e18);
    }
    
    function testIDASyncOnTransfer() public {
        // Mint tokens to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 2e18);
        
        // Transfer half to user2
        vm.prank(user1);
        poolShare.transfer(user2, 1e18);
        
        // Check IDA units
        assertEq(poolShare.getIDAUnits(user1), 1e18);
        assertEq(poolShare.getIDAUnits(user2), 1e18);
        
        // Verify IDA subscriptions
        (bool exist1, , uint128 units1, ) = ida.getSubscription(superToken, address(mockEscrow), INDEX_ID, user1);
        (bool exist2, , uint128 units2, ) = ida.getSubscription(superToken, address(mockEscrow), INDEX_ID, user2);
        
        assertTrue(exist1);
        assertTrue(exist2);
        assertEq(units1, 1e18);
        assertEq(units2, 1e18);
    }
    
    function testIDASyncOnTransferFrom() public {
        // Mint tokens to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 2e18);
        
        // Approve and transferFrom
        vm.prank(user1);
        poolShare.approve(user2, 1e18);
        
        vm.prank(user2);
        poolShare.transferFrom(user1, user2, 1e18);
        
        // Check IDA units
        assertEq(poolShare.getIDAUnits(user1), 1e18);
        assertEq(poolShare.getIDAUnits(user2), 1e18);
    }
    
    function testIDASyncManualSync() public {
        // Mint tokens
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 1e18);
        
        // Manual sync should work
        poolShare.syncIDAUnits(user1);
        assertEq(poolShare.getIDAUnits(user1), 1e18);
    }
    
    function testIDASyncMultipleTransfers() public {
        // Mint tokens to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 3e18);
        
        // Transfer to user2
        vm.prank(user1);
        poolShare.transfer(user2, 1e18);
        
        // Transfer from user2 to user1
        vm.prank(user2);
        poolShare.transfer(user1, 1e18);
        
        // Check final balances and IDA units
        assertEq(poolShare.balanceOf(user1), 3e18);
        assertEq(poolShare.balanceOf(user2), 0);
        assertEq(poolShare.getIDAUnits(user1), 3e18);
        assertEq(poolShare.getIDAUnits(user2), 0);
    }
    
    function testIDASyncComplexFlow() public {
        // Mint to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 2e18);
        
        // Transfer to user2
        vm.prank(user1);
        poolShare.transfer(user2, 1e18);
        
        // Mint more to user1
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 1e18);
        
        // Transfer from user2 to user1
        vm.prank(user2);
        poolShare.transfer(user1, 1e18);
        
        // Check final state
        assertEq(poolShare.balanceOf(user1), 3e18);
        assertEq(poolShare.balanceOf(user2), 0);
        assertEq(poolShare.getIDAUnits(user1), 3e18);
        assertEq(poolShare.getIDAUnits(user2), 0);
    }
    
    function testIDASyncFuzz(uint256 mintAmount, uint256 transferAmount) public {
        // Bound inputs
        mintAmount = bound(mintAmount, 1e18, 100e18);
        transferAmount = bound(transferAmount, 0, mintAmount);
        
        // Mint tokens
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, mintAmount);
        
        // Transfer if amount > 0
        if (transferAmount > 0) {
            vm.prank(user1);
            poolShare.transfer(user2, transferAmount);
        }
        
        // Verify IDA units match balances
        assertEq(poolShare.getIDAUnits(user1), poolShare.balanceOf(user1));
        assertEq(poolShare.getIDAUnits(user2), poolShare.balanceOf(user2));
        
        // Verify total IDA units match total supply
        assertEq(
            poolShare.getIDAUnits(user1) + poolShare.getIDAUnits(user2),
            poolShare.totalSupply()
        );
    }
    
    function testIDASyncNoEscrow() public {
        // Deploy new pool share without escrow
        vm.prank(owner);
        PoolShare newPoolShare = new PoolShare(
            "New Pool Share",
            "NPS",
            ida,
            superToken,
            INDEX_ID + 1
        );

        // Mint should fail without escrow
        vm.prank(address(mockEscrow));
        vm.expectRevert(PoolShare.OnlyEscrow.selector);
        newPoolShare.mint(user1, 1e18);

        // IDA units should be 0 since mint failed
        assertEq(newPoolShare.getIDAUnits(user1), 0);
    }
    
    function testIDASyncErrorHandling() public {
        // Test that IDA sync failures don't break token transfers
        // This would require a malicious mock, but we can test the basic flow
        
        // Mint tokens
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 1e18);
        
        // Transfer should work even if IDA sync has issues
        vm.prank(user1);
        poolShare.transfer(user2, 1e18);
        
        // Balances should be correct
        assertEq(poolShare.balanceOf(user1), 0);
        assertEq(poolShare.balanceOf(user2), 1e18);
    }

    function testIDASyncZeroBalance() public {
        // Mint and burn all shares
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 1e18);

        vm.prank(address(mockEscrow));
        poolShare.burn(user1, 1e18);

        // Units should be 0
        assertEq(poolShare.getIDAUnits(user1), 0);
    }

    function testIDASyncMaxUnits() public {
        uint128 maxUnits = type(uint128).max;
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, maxUnits);

        assertEq(poolShare.getIDAUnits(user1), maxUnits);
    }

    function testIDASyncRapidTransfers() public {
        vm.prank(address(mockEscrow));
        poolShare.mint(user1, 10e18);

        for (uint i = 0; i < 10; i++) {
            vm.prank(user1);
            poolShare.transfer(user2, 1e18);
            vm.prank(user2);
            poolShare.transfer(user1, 1e18);
        }

        assertEq(poolShare.getIDAUnits(user1), 10e18);
        assertEq(poolShare.getIDAUnits(user2), 0);
    }
}
