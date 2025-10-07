// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../interfaces/ISuperfluid.sol";
import "./MockERC20.sol";

/**
 * @title MockSuperToken
 * @dev Mock SuperToken for testing
 */
contract MockSuperToken is MockERC20, ISuperToken {
    address private _underlyingToken;
    
    constructor(
        string memory name_,
        string memory symbol_,
        address underlyingToken_
    ) MockERC20(name_, symbol_, 18, 0) {
        _underlyingToken = underlyingToken_;
    }
    
    function upgrade(uint256 amount) external override {
        // Transfer underlying tokens from sender
        IERC20(_underlyingToken).transferFrom(msg.sender, address(this), amount);
        // Mint super tokens to sender
        _mint(msg.sender, amount);
    }
    
    function downgrade(uint256 amount) external override {
        // Burn super tokens from sender
        _burn(msg.sender, amount);
        // Transfer underlying tokens to sender
        IERC20(_underlyingToken).transfer(msg.sender, amount);
    }
    
    function getUnderlyingToken() external view override returns (address) {
        return _underlyingToken;
    }
}

/**
 * @title MockIDA
 * @dev Mock Instant Distribution Agreement for testing
 */
contract MockIDA is IInstantDistributionAgreementV1 {
    struct Index {
        bool exist;
        uint128 indexValue;
        uint128 totalUnitsApproved;
        uint128 totalUnitsPending;
    }
    
    struct Subscription {
        bool exist;
        bool approved;
        uint128 units;
        uint256 pendingDistribution;
    }
    
    // publisher => token => indexId => Index
    mapping(address => mapping(address => mapping(uint32 => Index))) public indices;
    
    // token => publisher => indexId => subscriber => Subscription
    mapping(address => mapping(address => mapping(uint32 => mapping(address => Subscription)))) public subscriptions;
    
    function createIndex(
        ISuperToken token,
        uint32 indexId,
        bytes calldata
    ) external override {
        indices[msg.sender][address(token)][indexId] = Index({
            exist: true,
            indexValue: 0,
            totalUnitsApproved: 0,
            totalUnitsPending: 0
        });
    }
    
    function updateSubscription(
        ISuperToken token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata
    ) external override {
        Index storage index = indices[msg.sender][address(token)][indexId];
        require(index.exist, "Index does not exist");
        
        Subscription storage sub = subscriptions[address(token)][msg.sender][indexId][subscriber];
        
        // Handle subscription creation properly
        if (!sub.exist) {
            sub.exist = true;
            sub.approved = true;
            sub.units = 0; // Initialize to 0
        }
        
        // Update total units correctly
        uint128 oldUnits = sub.units;
        sub.units = units;
        
        if (units > oldUnits) {
            index.totalUnitsApproved += (units - oldUnits);
        } else if (units < oldUnits) {
            index.totalUnitsApproved -= (oldUnits - units);
        }
    }
    
    function distribute(
        ISuperToken token,
        uint32 indexId,
        uint256 amount,
        bytes calldata
    ) external override {
        Index storage index = indices[msg.sender][address(token)][indexId];
        require(index.exist, "Index does not exist");
        
        if (index.totalUnitsApproved == 0) return;
        
        // Transfer tokens from publisher - ensure proper approval
        token.transferFrom(msg.sender, address(this), amount);
        
        // Update index value (simplified)
        index.indexValue += uint128(amount / index.totalUnitsApproved);
        
        // In a real implementation, this would distribute to all subscribers
        // For testing, we'll just hold the tokens
    }
    
    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view override returns (
        bool exist,
        bool approved,
        uint128 units,
        uint256 pendingDistribution
    ) {
        Subscription storage sub = subscriptions[address(token)][publisher][indexId][subscriber];
        return (sub.exist, sub.approved, sub.units, sub.pendingDistribution);
    }
    
    function getIndex(
        ISuperToken token,
        address publisher,
        uint32 indexId
    ) external view override returns (
        bool exist,
        uint128 indexValue,
        uint128 totalUnitsApproved,
        uint128 totalUnitsPending
    ) {
        Index storage index = indices[publisher][address(token)][indexId];
        return (index.exist, index.indexValue, index.totalUnitsApproved, index.totalUnitsPending);
    }
}

/**
 * @title MockSuperfluid
 * @dev Mock Superfluid host for testing
 */
contract MockSuperfluid is ISuperfluid {
    address public ida;
    
    constructor(address ida_) {
        ida = ida_;
    }
    
    function getAgreementClass(bytes32) external view override returns (address) {
        return ida;
    }
    
    function callAgreement(
        address,
        bytes calldata,
        bytes calldata
    ) external pure override returns (bytes memory) {
        return "";
    }
}
