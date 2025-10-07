// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ISuperToken
 * @dev Interface for Superfluid SuperTokens
 */
interface ISuperToken is IERC20 {
    function upgrade(uint256 amount) external;
    function downgrade(uint256 amount) external;
    function getUnderlyingToken() external view returns (address);
}

/**
 * @title IInstantDistributionAgreementV1
 * @dev Interface for Superfluid Instant Distribution Agreement
 */
interface IInstantDistributionAgreementV1 {
    /**
     * @dev Create a new distribution index
     * @param token Super token address
     * @param indexId Index ID
     * @param userData User data
     */
    function createIndex(
        ISuperToken token,
        uint32 indexId,
        bytes calldata userData
    ) external;

    /**
     * @dev Update subscription units for an address
     * @param token Super token address
     * @param indexId Index ID
     * @param subscriber Subscriber address
     * @param units New units amount
     * @param userData User data
     */
    function updateSubscription(
        ISuperToken token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata userData
    ) external;

    /**
     * @dev Distribute tokens to index subscribers
     * @param token Super token address
     * @param indexId Index ID
     * @param amount Amount to distribute
     * @param userData User data
     */
    function distribute(
        ISuperToken token,
        uint32 indexId,
        uint256 amount,
        bytes calldata userData
    ) external;

    /**
     * @dev Get subscription details
     * @param token Super token address
     * @param publisher Publisher address
     * @param indexId Index ID
     * @param subscriber Subscriber address
     */
    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (
        bool exist,
        bool approved,
        uint128 units,
        uint256 pendingDistribution
    );

    /**
     * @dev Get index details
     * @param token Super token address
     * @param publisher Publisher address
     * @param indexId Index ID
     */
    function getIndex(
        ISuperToken token,
        address publisher,
        uint32 indexId
    ) external view returns (
        bool exist,
        uint128 indexValue,
        uint128 totalUnitsApproved,
        uint128 totalUnitsPending
    );
}

/**
 * @title ISuperfluid
 * @dev Interface for Superfluid Host contract
 */
interface ISuperfluid {
    function getAgreementClass(bytes32 agreementType) external view returns (address);
    
    function callAgreement(
        address agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);
}


