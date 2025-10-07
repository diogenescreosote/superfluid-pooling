# Adversarial Security Analysis
**Date**: October 7, 2025  
**Perspective**: Malicious Actor / Economic Attacker  
**Goal**: Identify exploits for disproportionate rewards, grief attacks, and systemic vulnerabilities

---

## Attack Vector Analysis

### 1. 🔴 CRITICAL: IDA Distribution Front-Running Attack

**Attack Scenario:**
```solidity
// Attacker observes pending forwardRevenue() or onAuctionSettled() tx in mempool
// Attacker front-runs with a large PoolShare transfer to themselves
// Distribution happens with attacker holding large balance
// Attacker immediately transfers shares back
```

**Mechanics:**
- `PoolShare._update()` syncs IDA units on EVERY transfer (lines 110-120)
- `Escrow.forwardRevenue()` distributes based on CURRENT IDA units (line 191)
- NO time-weighted or snapshot-based distribution

**Exploit Code:**
```solidity
// 1. Monitor mempool for forwardRevenue() with 10000 USDC
// 2. Front-run: buy 50% of pool shares (1000e18)
// 3. forwardRevenue() executes -> attacker gets 50% of 10000 USDC = 5000 USDC
// 4. Back-run: sell shares back immediately
// Result: Held shares for 1 block, extracted 50% of revenue
```

**Impact:** 
- **CRITICAL** - Attacker can extract disproportionate revenue by timing large purchases
- MEV bots can systematically extract value from legitimate stakers
- Makes long-term holding unprofitable vs. front-running

**Mitigation:**
- Implement time-weighted IDA units (accrue over time)
- Add distribution delay/buffer (e.g., 1 block after transfer)
- Use snapshot-based distributions
- Add transfer tax/cooldown

---

### 2. 🟠 HIGH: Auction Griefing via Dust Earnest

**Attack Scenario:**
```solidity
// Attacker initiates auction with 1 wei earnest money
// Reserve price = 1 wei, opening bid = 1 wei
// No legitimate bids (NFT worth millions but reserve is 1 wei)
// Attacker wins at 1 wei, others get dust distribution
```

**Mechanics:**
- `startAuction()` allows `earnestAmount > 0` with NO minimum (line 83)
- `earnestAmount` becomes both reserve AND opening bid (lines 106, 117)
- Attacker only needs 1e18 shares to initiate (line 85)

**Exploit Steps:**
1. Buy 1e18 shares (cost: ~1 NFT equivalent in pool)
2. Call `startAuction(collection, tokenId, 1 wei, 72 hours)`
3. Wait 72 hours, no legitimate bids due to absurd reserve
4. Attacker wins, gets NFT for 1 wei
5. Pool gets 1 wei distributed (essentially 0)

**Impact:**
- **HIGH** - NFTs can be extracted at near-zero cost
- Pool holders lose entire NFT value
- Requires only 1e18 shares (could be obtained legitimately)

**Current Mitigation:** 
- `InsufficientEarnest` check exists but only checks `> 0` (line 83)

**Required Fix:**
```solidity
uint256 public MIN_EARNEST = 1000e6; // 1000 USDC minimum
require(earnestAmount >= MIN_EARNEST, "Earnest too low");
```

---

### 3. 🟠 HIGH: Share Burn Timing Exploit

**Attack Scenario:**
```solidity
// Attacker deposits 1 NFT, gets 1e18 shares
// Attacker initiates auction (burns 1e18 shares upfront)
// totalNFTs decreases by 1, totalSupply decreases by 1e18
// Other holders now have HIGHER proportional shares
// If auction fails/reverts, shares are gone but NFT remains in contract
```

**Mechanics:**
- `burnSharesForAuction()` burns shares BEFORE auction starts (line 213)
- If auction creation fails on marketplace, shares are lost
- No refund mechanism if auction doesn't complete

**Exploit:**
1. Attacker deposits worthless NFT (if collection allowed)
2. Initiates auction, burns shares
3. Auction succeeds with collaborator bidding
4. Legitimate value extracted for worthless NFT

**Impact:**
- **MEDIUM-HIGH** - Depends on collection allowlist quality
- Can extract value for low-quality NFTs if pool accepts diverse collections

**Mitigation:**
- Strict curation of allowed collections (EXISTS: `allowedCollections` mapping)
- Minimum earnest requirements (NEEDED)
- Governance/DAO approval for auctions (OPTIONAL)

---

### 4. 🟡 MEDIUM: IDA Units Overflow Attack (Theoretical)

**Attack Scenario:**
```solidity
// IDA units are uint128, but balanceOf is uint256
// If someone holds > type(uint128).max tokens, IDA sync breaks
// Line 140: uint128 newUnits = uint128(currentBalance);
// Overflow causes wrong distribution calculations
```

**Mechanics:**
- `balanceOf()` returns uint256
- Cast to uint128 without bounds checking (PoolShare line 140)
- If `totalSupply > type(uint128).max`, distributions break

**Impact:**
- **LOW-MEDIUM** - Requires ~3.4e38 tokens to exist
- At 1e18 per NFT, needs 3.4e20 NFTs in pool (unrealistic)
- BUT: If SHARES_PER_NFT changes or decimal mismatch, possible

**Current State:** Not a realistic threat with current parameters

**Mitigation (Defensive):**
```solidity
require(currentBalance <= type(uint128).max, "Balance too large");
uint128 newUnits = uint128(currentBalance);
```

---

### 5. 🔴 CRITICAL: No Minimum Hold Period = Flash Loan Attack

**Attack Scenario:**
```solidity
// Within single transaction:
1. Flash loan 10M USDC
2. Buy all pool shares on DEX
3. Call forwardRevenue() (or wait for auction settlement in same block)
4. Receive 100% of distribution
5. Sell shares back to DEX
6. Repay flash loan + fees
7. Profit = distribution amount - flash loan fees
```

**Mechanics:**
- NO time locks on transfers
- NO minimum hold period for distributions
- IDA updates instantly on transfer (line 110-120)
- Attacker can enter/exit in single tx

**Exploit Code:**
```solidity
contract FlashAttack {
    function attack() external {
        // 1. Flash loan to buy shares
        lender.flashLoan(10_000_000e6);
        
        // 2. Buy all shares
        dex.swap(usdc, poolShare, 10_000_000e6);
        
        // 3. Front-run known distribution
        // (revenue already in escrow, just needs trigger)
        escrow.forwardRevenue();
        
        // 4. Receive 100% of distribution via IDA
        // 5. Sell shares
        dex.swap(poolShare, usdc, shares);
        
        // 6. Repay loan
        lender.repay(10_000_000e6 + fees);
        // Profit = distribution - fees
    }
}
```

**Impact:**
- **CRITICAL** - Complete extraction of all distributions
- Long-term holders get NOTHING
- System becomes unusable

**Mitigation Options:**
1. **Time-weighted distributions** (best)
2. **Snapshot-based** (at block N, distribute at N+100)
3. **Transfer cooldowns** (24 hour lock after transfer)
4. **Minimum hold period** (must hold 1 week to receive)

---

### 6. 🟡 MEDIUM: Auction Sniping at Exactly Reserve Price

**Attack Scenario:**
```solidity
// Auction starts with 1000 USDC reserve (earnest money)
// Attacker waits until last second
// Bids exactly 1000 USDC (reserve)
// Due to second-price mechanics, pays max(reserve, secondBid)
// If no other bids, pays 1000 USDC (reserve)
// Attacker gets NFT at minimum price, no competition
```

**Mechanics:**
- Opening bid = earnest amount (line 117)
- If no other bids, winner pays reserve (SettlementVault line 176)
- 72-hour auctions allow sniping strategies

**Impact:**
- **MEDIUM** - Reduces auction efficiency
- Legitimate but exploits game theory
- Pool gets reserve price, not market price

**Mitigation:**
- Extend auction on last-minute bids (time buffer - already exists)
- Higher minimum earnest requirements
- Consider English auction with bid visibility

---

### 7. 🟠 HIGH: Multiple Collection Attack

**Attack Scenario:**
```solidity
// Attacker deposits 10 worthless NFTs from allowed collection
// Gets 10e18 shares
// Pool now has 9 valuable NFTs + 10 worthless
// Attacker initiates auctions for valuable NFTs (has shares to burn)
// Auctions settle at market value
// Attacker receives ~50% of distribution (10/19 shares)
// Attacker extracted value from others' NFTs
```

**Mechanics:**
- No quality control beyond collection allowlist
- Within-collection value can vary dramatically (rare vs. common)
- Share issuance is 1:1 regardless of NFT value

**Impact:**
- **HIGH** if collection has varying value NFTs
- Floor NFTs can extract value from rare NFTs

**Mitigation:**
- Strict curation (only blue-chip, uniform collections)
- Per-NFT value weighting (complex, oracle-dependent)
- Separate pools per collection
- Governance approval for deposits

---

### 8. 🔴 CRITICAL: Owner Can Rug Pull

**Attack Scenario:**
```solidity
// Owner is Ownable single address (not DAO/multisig)
// Owner can:
1. pause() contract -> lock deposits/revenue
2. setAuctionAdapter(maliciousContract) -> steal NFTs
3. setSettlementVault(attackerWallet) -> redirect funds
4. rescueToken(poolShare, amount) -> steal shares
5. setApprovalForAll(...) -> approve attacker for NFT transfers
```

**Mechanics:**
- Centralized control (Ownable pattern)
- No timelock on critical functions
- No multisig requirement
- Emergency functions (`rescueToken`) very powerful

**Impact:**
- **CRITICAL** - Complete loss of funds/NFTs
- Requires trusting single owner
- Not suitable for decentralized use case

**Mitigation:**
```solidity
// 1. Transfer ownership to multisig (e.g., Gnosis Safe)
// 2. Add timelock for critical functions
contract TimelockEscrow {
    mapping(bytes32 => uint256) public timelocks;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    
    function proposeSetAuctionAdapter(address newAdapter) external onlyOwner {
        bytes32 proposal = keccak256(abi.encode("setAuctionAdapter", newAdapter));
        timelocks[proposal] = block.timestamp + TIMELOCK_DELAY;
    }
    
    function executeSetAuctionAdapter(address newAdapter) external onlyOwner {
        bytes32 proposal = keccak256(abi.encode("setAuctionAdapter", newAdapter));
        require(block.timestamp >= timelocks[proposal], "Timelock not expired");
        auctionAdapter = newAdapter;
    }
}
```

---

### 9. 🟡 MEDIUM: Auction Proceeds Manipulation

**Attack Scenario:**
```solidity
// SettlementVault.settle() uses usdc.balanceOf(this) (line 119)
// Attacker sends extra USDC to vault before settlement
// clearingPrice calculated incorrectly
// OR attacker frontrun-settles to drain previous auction proceeds
```

**Mechanics:**
- `proceedsReceived = usdc.balanceOf(address(this))` (line 119)
- Doesn't track per-auction proceeds accurately
- Multiple concurrent auctions can interfere

**Impact:**
- **MEDIUM** - Proceeds from auction A can be stolen by auction B
- Requires timing and multiple auctions

**Current Mitigation:**
- `settledAuctions` mapping prevents double-settlement (line 106)

**Needed Fix:**
```solidity
// Track proceeds per auction explicitly
mapping(uint256 => uint256) public auctionProceeds;

function receiveProceeds(uint256 auctionId, uint256 amount) external {
    require(msg.sender == address(marketplace), "Only marketplace");
    auctionProceeds[auctionId] = amount;
}

function settle(uint256 auctionId) external {
    uint256 proceedsReceived = auctionProceeds[auctionId];
    require(proceedsReceived > 0, "No proceeds");
    // ...
}
```

---

### 10. 🟠 HIGH: Superfluid IDA Distribution Failure

**Attack Scenario:**
```solidity
// Superfluid upgrade() or distribute() fails silently
// Lines 190, 241 have no return value checks
// Revenue gets stuck in contract
// Users don't receive distributions but think they did
```

**Mechanics:**
- `usdcx.upgrade(amount)` not checked (Escrow line 190, 241)
- `ida.distribute()` not checked (line 191, 242)
- If Superfluid paused/broken, funds stuck

**Impact:**
- **HIGH** - Revenue lost if Superfluid has issues
- No fallback mechanism

**Mitigation:**
```solidity
// Add return checks and fallback
try usdcx.upgrade(usdcBalance) returns (bool success) {
    require(success, "USDCx upgrade failed");
} catch {
    // Fallback: keep USDC, manual distribution
    emit UpgradeFailed(usdcBalance);
    return;
}
```

---

## Economic Attack Vectors

### 11. Sybil Attack on Distributions

**Setup:** Attacker creates 100 addresses, each holding small amounts of poolShare  
**Attack:** Attacker triggers distribution, incurs gas costs across 100 IDA updates  
**Result:** Either gas griefing OR profitable if distribution > gas costs

**Mitigation:** IDA is gas-efficient; this is not economical

### 12. Auction Spam

**Setup:** Attacker with 1e18 shares repeatedly initiates auctions  
**Attack:** Creates 100 auctions with minimum earnest, all for same NFT (will fail after first)  
**Result:** Gas costs for legitimate users trying to interact

**Mitigation:** 
- Auctions check `holdsNFT` (line 82)
- Only one auction per NFT possible
- Attacker wastes own gas + burns shares

---

## Recommendations (Priority Order)

### CRITICAL Fixes (Deploy Blocker)
1. **Flash Loan Protection**: Implement time-weighted IDA or transfer cooldowns
2. **Minimum Earnest**: Set 1000 USDC minimum for auctions
3. **Ownership Decentralization**: Transfer to multisig + add timelocks
4. **Front-Run Protection**: Add transfer delay before distribution eligibility

### HIGH Priority
5. **Collection Curation**: Strict allowlist, uniform value NFTs only
6. **Proceeds Tracking**: Per-auction accounting in SettlementVault
7. **Superfluid Checks**: Add error handling for upgrade/distribute failures

### MEDIUM Priority
8. **Auction Parameters**: Add DAO governance for auction approvals
9. **Emergency Pause**: Already exists, ensure monitored
10. **Overflow Guards**: Add defensive checks for IDA uint128 casts

---

## Audit Conclusion

**Most Critical Vulnerability**: Flash loan / front-running attacks on distributions

**Recommended Action Plan**:
1. Add 24-hour transfer lock for distribution eligibility
2. Implement snapshot-based distributions (block N → distribute at N+1000)
3. Set minimum earnest = 1000 USDC
4. Deploy to multisig ownership
5. External audit focusing on economic exploits

**Current Risk Level**: **HIGH** - Do not deploy to mainnet without fixes


