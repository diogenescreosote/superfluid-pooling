// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/PoolShare.sol";
import "../src/Escrow.sol";
import "../src/AuctionAdapter.sol";
import "../src/SettlementVault.sol";
import "../src/interfaces/ISuperfluid.sol";
import "../src/interfaces/IMarketplace.sol";

/**
 * @title Deploy
 * @dev Deployment script for the NFT Pool system
 * 
 * Usage:
 * forge script script/Deploy.s.sol:Deploy --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast --verify
 * 
 * Or with environment variables:
 * forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
 */
contract Deploy is Script {
    // Deployment configuration - update these for your target network
    
    // Mainnet Superfluid addresses
    address constant SUPERFLUID_HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA_ADDRESS = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant USDC_ADDRESS = 0xa0b86a33e6441e5f6F7b6e1b17d8B4b8F7d4E3A5; // Update with actual USDC
    address constant USDCX_ADDRESS = 0x1BA8603DA702602A8657980e825A6DAa03Dee93a; // Update with actual USDCx
    
    // thirdweb Marketplace V3 address (update for your network)
    address constant MARKETPLACE_ADDRESS = 0x0000000000000000000000000000000000000000; // Update with actual marketplace
    
    // NFT collections to allow initially (update as needed)
    address[] allowedCollections = [
        0x0000000000000000000000000000000000000000 // Add actual NFT collection addresses
    ];
    
    // Default parameters
    uint32 constant INDEX_ID = 0;
    string constant POOL_NAME = "NFT Pool Share";
    string constant POOL_SYMBOL = "NPS";
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying contracts with deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy PoolShare
        console.log("Deploying PoolShare...");
        PoolShare poolShare = new PoolShare(
            POOL_NAME,
            POOL_SYMBOL,
            IInstantDistributionAgreementV1(IDA_ADDRESS),
            ISuperToken(USDCX_ADDRESS),
            INDEX_ID
        );
        console.log("PoolShare deployed at:", address(poolShare));
        
        // 2. Deploy Escrow
        console.log("Deploying Escrow...");
        Escrow escrow = new Escrow(
            poolShare,
            IERC20(USDC_ADDRESS),
            ISuperToken(USDCX_ADDRESS),
            IInstantDistributionAgreementV1(IDA_ADDRESS),
            INDEX_ID,
            allowedCollections
        );
        console.log("Escrow deployed at:", address(escrow));
        
        // 3. Set escrow in PoolShare
        console.log("Setting escrow in PoolShare...");
        poolShare.setEscrow(address(escrow));
        
        // 4. Deploy SettlementVault (placeholder for AuctionAdapter)
        console.log("Deploying SettlementVault...");
        SettlementVault settlementVault = new SettlementVault(
            IMarketplace(MARKETPLACE_ADDRESS),
            escrow,
            AuctionAdapter(address(0)), // Will update after AuctionAdapter deployment
            IERC20(USDC_ADDRESS)
        );
        console.log("SettlementVault deployed at:", address(settlementVault));
        
        // 5. Deploy AuctionAdapter
        console.log("Deploying AuctionAdapter...");
        AuctionAdapter auctionAdapter = new AuctionAdapter(
            IMarketplace(MARKETPLACE_ADDRESS),
            escrow,
            IERC20(USDC_ADDRESS),
            address(settlementVault)
        );
        console.log("AuctionAdapter deployed at:", address(auctionAdapter));
        
        // 6. Set settlement vault in Escrow
        console.log("Setting settlement vault in Escrow...");
        escrow.setSettlementVault(address(settlementVault));
        
        // 7. Transfer ownership to deployer (they're already owner, but this confirms it)
        console.log("Confirming ownership...");
        console.log("PoolShare owner:", poolShare.owner());
        console.log("Escrow owner:", escrow.owner());
        console.log("AuctionAdapter owner:", auctionAdapter.owner());
        console.log("SettlementVault owner:", settlementVault.owner());
        
        vm.stopBroadcast();
        
        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: (check your RPC URL)");
        console.log("Deployer:", deployer);
        console.log("PoolShare:", address(poolShare));
        console.log("Escrow:", address(escrow));
        console.log("AuctionAdapter:", address(auctionAdapter));
        console.log("SettlementVault:", address(settlementVault));
        console.log("\n=== CONFIGURATION ===");
        console.log("USDC:", USDC_ADDRESS);
        console.log("USDCx:", USDCX_ADDRESS);
        console.log("Superfluid IDA:", IDA_ADDRESS);
        console.log("Marketplace:", MARKETPLACE_ADDRESS);
        console.log("Index ID:", INDEX_ID);
        console.log("Pool Name:", POOL_NAME);
        console.log("Pool Symbol:", POOL_SYMBOL);
        
        // Save addresses to file for verification
        _saveDeploymentAddresses(
            address(poolShare),
            address(escrow),
            address(auctionAdapter),
            address(settlementVault)
        );
    }
    
    function _saveDeploymentAddresses(
        address poolShare,
        address escrow,
        address auctionAdapter,
        address settlementVault
    ) internal {
        string memory json = string(abi.encodePacked(
            '{\n',
            '  "poolShare": "', vm.toString(poolShare), '",\n',
            '  "escrow": "', vm.toString(escrow), '",\n',
            '  "auctionAdapter": "', vm.toString(auctionAdapter), '",\n',
            '  "settlementVault": "', vm.toString(settlementVault), '",\n',
            '  "usdc": "', vm.toString(USDC_ADDRESS), '",\n',
            '  "usdcx": "', vm.toString(USDCX_ADDRESS), '",\n',
            '  "ida": "', vm.toString(IDA_ADDRESS), '",\n',
            '  "marketplace": "', vm.toString(MARKETPLACE_ADDRESS), '",\n',
            '  "indexId": ', vm.toString(INDEX_ID), '\n',
            '}'
        ));
        
        vm.writeFile("deployments.json", json);
        console.log("Deployment addresses saved to deployments.json");
    }
}

/**
 * @title DeployMocks
 * @dev Deployment script for mock contracts (testing/development)
 */
contract DeployMocks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying mock contracts with deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy mocks (implementation would go here)
        // This is useful for local testing and development
        
        vm.stopBroadcast();
    }
}
