# NFT Pool with Superfluid IDA + Modular Auctions

A comprehensive implementation of an ERC-20 pool token system with Superfluid Instant Distribution Agreement (IDA) for instant revenue sharing and modular auction-based redemption.

## Overview

This system implements a novel approach to NFT fractionalization and revenue distribution:

- **Pass-through payouts**: Revenue is instantly distributed to pool token holders via Superfluid IDA
- **Wallet visibility**: Uses only ERC-20 (pool tokens) and ERC-721 (underlying NFTs) - no ERC-1155
- **Auction-only redemption**: NFTs can only be redeemed through auctions with earnest money
- **Second-price mechanics**: Winners pay the second-highest bid amount
- **Audited-first stack**: Reuses battle-tested components (Superfluid, thirdweb Marketplace)

## Architecture

### Core Components

1. **PoolShare (ERC-20)**: Tradeable pool tokens with IDA synchronization
2. **Escrow**: NFT custody and revenue distribution hub
3. **AuctionAdapter**: Interface to external auction marketplaces
4. **SettlementVault**: Second-price settlement and proceeds routing

### Key Features

- **Instant Distribution**: No epochs, no snapshots - revenue flows immediately to current holders
- **Permissionless Auctions**: Anyone can start an auction by posting earnest money
- **Modular Design**: Swap auction engines without touching core contracts
- **Invariant Protection**: `totalSupply == totalNFTs × 1e18` maintained at all times

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 16+ (for package management)

### Installation

```bash
git clone <repository-url>
cd split
forge install
```

### Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testFullAuctionFlow
```

### Deployment

1. Copy and configure environment variables:
```bash
cp env.example .env
# Edit .env with your configuration
```

2. Deploy to testnet:
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url $TESTNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

3. Verify contracts:
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url $TESTNET_RPC_URL --private-key $PRIVATE_KEY --verify
```

## Usage Guide

### For Pool Participants

#### Depositing NFTs
```solidity
// Approve NFT transfer
nft.approve(address(escrow), tokenId);

// Deposit NFT and receive pool tokens
uint256[] memory tokenIds = [tokenId];
escrow.deposit(nftCollection, tokenIds);

// You now have 1e18 pool tokens per NFT deposited
```

#### Receiving Revenue
Revenue is automatically distributed to your wallet as USDCx (Superfluid token):

```solidity
// Check your USDCx balance
uint256 usdcxBalance = usdcx.balanceOf(yourAddress);

// Convert USDCx back to USDC anytime
usdcx.downgrade(usdcxBalance);
```

### For Auction Participants

#### Starting an Auction
```solidity
// Approve earnest money (e.g., 500 USDC)
usdc.approve(address(auctionAdapter), earnestAmount);

// Start auction (earnest money becomes opening bid and reserve price)
uint256 listingId = auctionAdapter.startAuction(
    nftCollection,
    tokenId,
    earnestAmount,
    72 hours  // duration
);
```

#### Bidding
Use the marketplace interface directly:
```solidity
// Approve bid amount
usdc.approve(address(marketplace), bidAmount);

// Place bid
marketplace.offer(listingId, 1, address(usdc), bidAmount, deadline);
```

#### Settlement
Anyone can settle after auction ends:
```solidity
settlementVault.settle(listingId);
```

### For Operators

#### Revenue Distribution
```solidity
// When USDC accumulates in escrow from operations
escrow.forwardRevenue();  // Converts to USDCx and distributes instantly
```

## Contract Addresses

### Mainnet
- PoolShare: `TBD`
- Escrow: `TBD`
- AuctionAdapter: `TBD`
- SettlementVault: `TBD`

### Polygon
- PoolShare: `TBD`
- Escrow: `TBD`
- AuctionAdapter: `TBD`
- SettlementVault: `TBD`

## Technical Details

### Pool Token Economics
- **Decimals**: 18
- **Supply**: 1e18 tokens per NFT in escrow
- **Transfers**: Automatically sync with Superfluid IDA units

### Revenue Distribution
- **Source**: USDC from leasing, royalties, or other operations
- **Mechanism**: Instant distribution via Superfluid IDA
- **Token**: USDCx (upgradeable/downgradeable with USDC)

### Auction Mechanics
- **Initiation**: Anyone can start by posting earnest money
- **Reserve**: Earnest money amount
- **Settlement**: Second-price (winner pays second-highest bid)
- **Proceeds**: Flow through same revenue distribution system

### Security Features
- **Invariant Protection**: Total supply always equals NFT count × 1e18
- **Reentrancy Guards**: All state-changing functions protected
- **Access Controls**: Role-based permissions for critical functions
- **Emergency Functions**: Owner can rescue stuck tokens

## Integration Guide

### Superfluid Setup
```solidity
// Required Superfluid contracts
ISuperfluid host = ISuperfluid(SUPERFLUID_HOST);
IInstantDistributionAgreementV1 ida = IInstantDistributionAgreementV1(IDA_ADDRESS);
ISuperToken usdcx = ISuperToken(USDCX_ADDRESS);
```

### Marketplace Integration
Currently supports thirdweb Marketplace V3. To add support for other marketplaces:

1. Implement marketplace-specific adapter
2. Ensure it follows the `IMarketplace` interface
3. Update settlement vault to handle marketplace-specific settlement

### Frontend Integration
```javascript
// Check pool token balance
const poolBalance = await poolShare.balanceOf(userAddress);

// Check USDCx received
const usdcxBalance = await usdcx.balanceOf(userAddress);

// Start auction
const tx = await auctionAdapter.startAuction(
    nftAddress,
    tokenId,
    earnestAmount,
    duration
);
```

## Development

### Project Structure
```
├── src/
│   ├── PoolShare.sol           # ERC-20 pool token with IDA sync
│   ├── Escrow.sol              # NFT custody and revenue distribution
│   ├── AuctionAdapter.sol      # Marketplace integration
│   ├── SettlementVault.sol     # Second-price settlement
│   ├── interfaces/             # External contract interfaces
│   └── mocks/                  # Mock contracts for testing
├── test/                       # Comprehensive test suite
├── script/                     # Deployment scripts
└── README.md                   # This file
```

### Adding New Features

1. **New Auction Engine**: Implement `IMarketplace` interface
2. **Additional Revenue Sources**: Add to `Escrow.forwardRevenue()`
3. **Compliance Features**: Extend `PoolShare` transfer hooks
4. **Advanced Settlement**: Enhance `SettlementVault` logic

### Testing Strategy

- **Unit Tests**: Each contract tested in isolation
- **Integration Tests**: Full flow testing with all components
- **Invariant Tests**: Verify system invariants hold
- **Fuzz Tests**: Random input testing for edge cases

## Security Considerations

### Auditing Approach
- **Modular Design**: Each component can be audited separately
- **External Dependencies**: Relies on audited Superfluid and marketplace contracts
- **Minimal Custom Logic**: Reduces attack surface

### Known Limitations
- **Marketplace Dependency**: Relies on external marketplace for auction mechanics
- **Superfluid Dependency**: Requires Superfluid protocol for distribution
- **Second-Price Implementation**: Simplified for MVP (can be enhanced)

## Gas Optimization

- **Batch Operations**: Support for multi-NFT deposits
- **Efficient IDA Updates**: Only update when balances change
- **Minimal Storage**: Lean data structures

## Roadmap

### Phase 1 (Current)
- ✅ Core contracts implementation
- ✅ Comprehensive testing
- ✅ Deployment scripts
- ✅ Documentation

### Phase 2 (Next)
- [ ] Enhanced second-price mechanics
- [ ] Multiple marketplace support
- [ ] Advanced analytics dashboard
- [ ] Governance token integration

### Phase 3 (Future)
- [ ] Cross-chain deployment
- [ ] Advanced compliance features
- [ ] Automated market making
- [ ] DAO governance

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- Documentation: This README and inline code comments
- Issues: GitHub Issues tracker
- Community: [Discord/Telegram link]

## Acknowledgments

- [Superfluid Protocol](https://superfluid.finance/) for instant distribution infrastructure
- [thirdweb](https://thirdweb.com/) for marketplace contracts
- [OpenZeppelin](https://openzeppelin.com/) for security-focused base contracts
- [Foundry](https://book.getfoundry.sh/) for development framework