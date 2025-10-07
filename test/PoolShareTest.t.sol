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

contract PoolShareTest is Test {
    PoolShare public poolShare;
    MockIDA public ida;
    MockSuperToken public superToken;
    MockERC20 public usdc;
    
    address public owner = address(0x1);
    address public escrow = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    
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
            INDEX_ID,
            0 // No minimum hold period for tests
        );
        
        // Set escrow
        poolShare.setEscrow(escrow);
        
        vm.stopPrank();
    }
    
    function testInitialState() public {
        assertEq(poolShare.name(), "Pool Share Token");
        assertEq(poolShare.symbol(), "PST");
        assertEq(poolShare.decimals(), 18);
        assertEq(poolShare.totalSupply(), 0);
        assertEq(address(poolShare.ida()), address(ida));
        assertEq(address(poolShare.superToken()), address(superToken));
        assertEq(poolShare.indexId(), INDEX_ID);
        assertEq(poolShare.escrow(), escrow);
    }
    
    function testSetEscrow() public {
        // Deploy new pool share to test escrow setting
        vm.startPrank(owner);
        PoolShare newPoolShare = new PoolShare(
            "New Pool Share",
            "NPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );
        
        // Should be able to set escrow once
        newPoolShare.setEscrow(escrow);
        assertEq(newPoolShare.escrow(), escrow);
        
        // Should not be able to set escrow again
        vm.expectRevert(PoolShare.EscrowAlreadySet.selector);
        newPoolShare.setEscrow(address(0x5));
        
        vm.stopPrank();
    }
    
    function testMintOnlyEscrow() public {
        // Deploy new pool share for this test
        vm.prank(owner);
        PoolShare testPoolShare = new PoolShare(
            "Test Pool Share",
            "TPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );

        // Deploy mock escrow
        MockEscrow testEscrow = new MockEscrow(ida, superToken, INDEX_ID);

        // Set escrow
        vm.prank(owner);
        testPoolShare.setEscrow(address(testEscrow));

        // Create IDA index
        vm.prank(address(testEscrow));
        ida.createIndex(superToken, INDEX_ID, "");

        // Non-escrow should not be able to mint
        vm.prank(user1);
        vm.expectRevert(PoolShare.OnlyEscrow.selector);
        testPoolShare.mint(user1, 1e18);

        // Escrow should be able to mint
        vm.prank(address(testEscrow));
        testPoolShare.mint(user1, 1e18);
        assertEq(testPoolShare.balanceOf(user1), 1e18);
        assertEq(testPoolShare.totalSupply(), 1e18);
    }
    
    function testBurnOnlyEscrow() public {
        // Deploy new pool share for this test
        vm.prank(owner);
        PoolShare testPoolShare = new PoolShare(
            "Test Pool Share",
            "TPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );

        // Deploy mock escrow
        MockEscrow testEscrow = new MockEscrow(ida, superToken, INDEX_ID);

        // Set escrow
        vm.prank(owner);
        testPoolShare.setEscrow(address(testEscrow));

        // Create IDA index
        vm.prank(address(testEscrow));
        ida.createIndex(superToken, INDEX_ID, "");

        // First mint some tokens
        vm.prank(address(testEscrow));
        testPoolShare.mint(user1, 1e18);

        // Non-escrow should not be able to burn
        vm.prank(user1);
        vm.expectRevert(PoolShare.OnlyEscrow.selector);
        testPoolShare.burn(user1, 1e18);

        // Escrow should be able to burn
        vm.prank(address(testEscrow));
        testPoolShare.burn(user1, 1e18);
        assertEq(testPoolShare.balanceOf(user1), 0);
        assertEq(testPoolShare.totalSupply(), 0);
    }
    
    function testTransferUpdatesIDAUnits() public {
        // Deploy a new pool share for this test
        vm.prank(owner);
        PoolShare testPoolShare = new PoolShare(
            "Test Pool Share",
            "TPS",
            ida,
            superToken,
            INDEX_ID,
            0
        );
        
        // Deploy a mock escrow that implements the IEscrow interface
        MockEscrow mockEscrow = new MockEscrow(ida, superToken, INDEX_ID);
        
        // Set the mock escrow in pool share
        vm.prank(owner);
        testPoolShare.setEscrow(address(mockEscrow));
        
        // Create IDA index
        vm.prank(address(mockEscrow));
        ida.createIndex(superToken, INDEX_ID, "");
        
        // Mint tokens to user1
        vm.prank(address(mockEscrow));
        testPoolShare.mint(user1, 2e18);
        
        // Check IDA units for user1
        assertEq(testPoolShare.getIDAUnits(user1), 2e18);
        assertEq(testPoolShare.getIDAUnits(user2), 0);
        
        // Transfer half to user2
        vm.prank(user1);
        testPoolShare.transfer(user2, 1e18);
        
        // Check updated balances and IDA units
        assertEq(testPoolShare.balanceOf(user1), 1e18);
        assertEq(testPoolShare.balanceOf(user2), 1e18);
        assertEq(testPoolShare.getIDAUnits(user1), 1e18);
        assertEq(testPoolShare.getIDAUnits(user2), 1e18);
    }
    
    function testSyncIDAUnits() public {
        // Deploy a new pool share for this test
        vm.prank(owner);
        PoolShare testPoolShare = new PoolShare(
            "Test Pool Share 2",
            "TPS2",
            ida,
            superToken,
            INDEX_ID + 1, // Use different index ID
            0
        );
        
        // Deploy a mock escrow that implements the IEscrow interface
        MockEscrow mockEscrow = new MockEscrow(ida, superToken, INDEX_ID + 1);
        
        // Set the mock escrow in pool share
        vm.prank(owner);
        testPoolShare.setEscrow(address(mockEscrow));
        
        // Create IDA index
        vm.prank(address(mockEscrow));
        ida.createIndex(superToken, INDEX_ID + 1, "");
        
        // Mint tokens
        vm.prank(address(mockEscrow));
        testPoolShare.mint(user1, 1e18);
        
        // Manual sync should work
        testPoolShare.syncIDAUnits(user1);
        assertEq(testPoolShare.getIDAUnits(user1), 1e18);
    }
    
    function testCannotSetZeroAddressAsEscrow() public {
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
        
        vm.stopPrank();
    }
    
    function testConstructorValidatesAddresses() public {
        vm.startPrank(owner);
        
        // Should revert with zero IDA address
        vm.expectRevert(PoolShare.ZeroAddress.selector);
        new PoolShare(
            "Pool Share",
            "PS",
            IInstantDistributionAgreementV1(address(0)),
            superToken,
            INDEX_ID,
            0
        );
        
        // Should revert with zero SuperToken address
        vm.expectRevert(PoolShare.ZeroAddress.selector);
        new PoolShare(
            "Pool Share",
            "PS",
            ida,
            ISuperToken(address(0)),
            INDEX_ID,
            0
        );
        
        vm.stopPrank();
    }
}
