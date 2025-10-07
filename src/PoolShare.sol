// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISuperfluid.sol";

// Forward declaration to avoid circular import
interface IEscrow {
    function updateIDASubscription(address account, uint128 units) external;
}

/**
 * @title PoolShare
 * @dev ERC-20 token representing shares in the NFT pool with Superfluid IDA integration
 * Synchronizes token balances with IDA units for instant distribution
 */
contract PoolShare is ERC20Burnable, Ownable {
    /// @notice Superfluid IDA contract
    IInstantDistributionAgreementV1 public immutable ida;
    
    /// @notice SuperToken for distributions (USDCx)
    ISuperToken public immutable superToken;
    
    /// @notice Index ID for IDA distributions
    uint32 public immutable indexId;
    
    /// @notice Minimum hold period before receiving distributions (blocks)
    uint256 public immutable minHoldPeriod;
    
    /// @notice Escrow contract address (only address that can mint/burn)
    address public escrow;
    
    /// @notice Decimals for the token (18 to match 1e18 per NFT)
    uint8 private constant DECIMALS = 18;
    
    /// @notice Track last transfer block for each address
    mapping(address => uint256) public lastTransferBlock;
    
    event EscrowSet(address indexed escrow);
    event IDAUnitsUpdated(address indexed account, uint256 oldUnits, uint256 newUnits);
    
    error OnlyEscrow();
    error EscrowAlreadySet();
    error ZeroAddress();
    
    /**
     * @dev Constructor
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param ida_ Superfluid IDA contract
     * @param superToken_ SuperToken for distributions
     * @param indexId_ Index ID for IDA
     */
    constructor(
        string memory name_,
        string memory symbol_,
        IInstantDistributionAgreementV1 ida_,
        ISuperToken superToken_,
        uint32 indexId_,
        uint256 minHoldPeriod_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        if (address(ida_) == address(0) || address(superToken_) == address(0)) {
            revert ZeroAddress();
        }
        
        ida = ida_;
        superToken = superToken_;
        indexId = indexId_;
        minHoldPeriod = minHoldPeriod_;
    }
    
    /**
     * @dev Set the escrow contract address (one-time only)
     * @param escrow_ Escrow contract address
     */
    function setEscrow(address escrow_) external onlyOwner {
        if (escrow != address(0)) revert EscrowAlreadySet();
        if (escrow_ == address(0)) revert ZeroAddress();
        
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }
    
    /**
     * @dev Mint tokens (only escrow can call)
     * @param to Recipient address
     * @param amount Amount to mint (should be 1e18 per NFT)
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != escrow) revert OnlyEscrow();
        _mint(to, amount);
    }
    
    /**
     * @dev Burn tokens (only escrow can call)
     * @param from Address to burn from
     * @param amount Amount to burn (should be 1e18 per NFT)
     */
    function burn(address from, uint256 amount) external {
        if (msg.sender != escrow) revert OnlyEscrow();
        _burn(from, amount);
    }
    
    /**
     * @dev Override decimals to return 18
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
    
    /**
     * @dev Hook called after token transfers to sync IDA units
     * @param from Source address
     * @param to Destination address  
     * @param amount Amount transferred
     */
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        
        // Update last transfer block for recipient (resets hold period)
        if (to != address(0) && to != address(escrow)) {
            lastTransferBlock[to] = block.number;
        }
        
        // Update IDA units for both addresses
        if (from != address(0)) {
            _updateIDAUnits(from);
        }
        if (to != address(0)) {
            _updateIDAUnits(to);
        }
    }
    
    /**
     * @dev Update IDA units for an address to match token balance
     * @param account Address to update
     */
    function _updateIDAUnits(address account) internal {
        // Skip if escrow is not set yet
        if (escrow == address(0)) return;
        
        uint256 currentBalance = balanceOf(account);
        
        // Get current IDA subscription
        (bool exist, , uint128 currentUnits, ) = ida.getSubscription(
            superToken,
            escrow,
            indexId,
            account
        );
        
        // Check if account has held tokens for minimum period
        // If not, set IDA units to 0 (no distribution eligibility)
        uint128 newUnits;
        if (block.number >= lastTransferBlock[account] + minHoldPeriod) {
            newUnits = uint128(currentBalance);
        } else {
            newUnits = 0; // Not eligible for distributions yet
        }
        
        // Only update if units changed
        if (!exist || currentUnits != newUnits) {
            // Call escrow to update IDA units (escrow is the publisher)
            IEscrow(escrow).updateIDASubscription(account, newUnits);
            emit IDAUnitsUpdated(account, currentUnits, newUnits);
        }
    }
    
    /**
     * @dev Manual IDA units sync for an address (emergency function)
     * @param account Address to sync
     */
    function syncIDAUnits(address account) external {
        _updateIDAUnits(account);
    }
    
    /**
     * @dev Get IDA units for an address
     * @param account Address to check
     * @return units Current IDA units
     */
    function getIDAUnits(address account) external view returns (uint128 units) {
        (, , units, ) = ida.getSubscription(superToken, escrow, indexId, account);
    }
}

