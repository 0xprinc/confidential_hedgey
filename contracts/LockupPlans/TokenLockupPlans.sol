// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "../ERC721Delegate/ERC721Delegate.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/TimelockLibrary.sol";
import "../sharedContracts/URIAdmin.sol";
import "../sharedContracts/LockupStorage.sol";
import "fhevm/lib/TFHE.sol";
import "fhevm/gateway/GatewayCaller.sol";

/// @title TokenLockupPlans - An efficient way to allocate tokens to beneficiaries that unlock over time
/// @notice This contract allows people to grant tokens to beneficiaries that unlock over time with the added functionalities;
/// Owners of unlock plans can manage all of their token unlocks across all of their positions in a single contract.
/// Each lockup plan is a unique NFT, leveraging the backbone of the ERC721 contract to represent a unique lockup plan
/// 1. Not-Revokable: plans cannot be revoked, once granted the entire amount will be claimable by the beneficiary over time.
/// 2. Transferable: Lockup plans can be transferred by the owner - opening up defi opportunities like NFT sales, borrowing and lending, and many others.
/// 3. Governance optimized for snapshot voting: These are built to allow beneficiaries to vote with their locked tokens on snapshot, or delegate them to other delegatees
/// 4. Beneficiary Claims: Beneficiaries get to choose when to claim their tokens, and can claim partial amounts that are less than the amount they have unlocked for tax optimization
/// 5. Segmenting plans: Beneficiaries can segment a single lockup into  smaller chunks for subdelegation of tokens, or to use in defi with smaller chunks
/// 6. Combingin Plans: Beneficiaries can combine plans that have the same details in one larger chunk for easier bulk management

contract TokenLockupPlans is ERC721Delegate, LockupStorage, ReentrancyGuard, URIAdmin, GatewayCaller {
    /// @notice uses counters for incrementing token IDs which are the planIds
    using Counters for Counters.Counter;
    Counters.Counter private _planIds;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {
        uriAdmin = msg.sender;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    mapping(uint256 => bool) public decryptedValues;

    mapping(uint256 => planVars) public planVarsMap;

    struct planVars {
        address recipient;
        address token;
        euint64 amount;
        euint64 start;
        euint64 cliff;
        euint64 end;
        uint256 rate;
        uint256 period;
    }

    /****CORE EXTERNAL FUNCTIONS*********************************************************************************************************************************************/
    /// @notice function to create a lockup plan.
    /// @dev this function will pull the tokens into this contract for escrow, increment the planIds, mint an NFT to the recipient, and create the storage Plan and map it to the newly minted NFT token ID in storage
    /// @param recipient the address of the recipient and beneficiary of the plan
    /// @param token the address of the ERC20 token
    /// @param amount the amount of tokens to be locked in the plan
    /// @param start the start date of the lockup plan, unix time
    /// @param cliff a cliff date which is a discrete date where tokens are not unlocked until this date, and then vest in a large single chunk on the cliff date
    /// @param rate the amount of tokens that vest in a single period
    /// @param period the amount of time in between each unlock time stamp, in seconds. A period of 1 means that tokens vest every second in a 'streaming' style.
    function createPlan(
        address recipient,
        address token,
        einput amount,
        einput start,
        einput cliff,
        uint256 rate,
        uint256 period,
        bytes calldata inputProof
    ) external nonReentrant returns (uint256 requestID) {
        euint64 amount_ = TFHE.asEuint64(amount, inputProof);
        euint64 start_ = TFHE.asEuint64(start, inputProof);
        euint64 cliff_ = TFHE.asEuint64(cliff, inputProof);
        require(recipient != address(0), "0_recipient");
        require(token != address(0), "0_token");
        (euint64 end, ebool valid) = TimelockLibrary.validateEnd(start_, cliff_, amount_, rate, period);
        planVarsMap[_planIds.current()] = planVars(recipient, token, amount_, start_, cliff_, end, rate, period);

        // require(valid);

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(valid);
        requestID = Gateway.requestDecryption(cts, this.createPlanCustomCallback.selector, 0, block.timestamp + 1e4, false);
    }

    function createPlanCustomCallback(uint256 requestId, bool decryptedInput) public onlyGateway returns (bool) {
        decryptedValues[requestId] = decryptedInput;
        return decryptedInput;
    }

    function completeCreatePlan(uint256 requestId) public returns (uint256 newPlanId) {
        planVars memory plan = planVarsMap[requestId];
        _planIds.increment();
        newPlanId = _planIds.current();
        TransferHelper.transferTokens(plan.token, msg.sender, address(this), plan.amount);
        plans[newPlanId] = Plan(plan.token, plan.amount, plan.start, plan.cliff, plan.rate, plan.period);
        _safeMint(plan.recipient, newPlanId);
        emit PlanCreated(
            newPlanId,
            plan.recipient,
            plan.token,
            plan.amount,
            plan.start,
            plan.cliff,
            plan.end,
            plan.rate,
            plan.period
        );
    }

    /// @notice function for a beneficiary to redeem unlocked tokens from a group of plans
    /// @dev this will call an internal function for processing the actual redemption of tokens, which will withdraw unlocked tokens and deliver them to the beneficiary
    /// @dev this function will redeem all claimable and unlocked tokens up to the current block.timestamp
    /// @param planIds is the array of the NFT planIds that are to be redeemed. If any have no redeemable balance they will be skipped.
    function redeemPlans(uint256[] calldata planIds) external nonReentrant returns(uint256){
        return _redeemPlans(planIds, block.timestamp);
    }

    /// @notice function for a beneficiary to redeem unlocked tokens from a group of plans
    /// @dev this will call an internal function for processing the actual redemption of tokens, which will withdraw unlocked tokens and deliver them to the beneficiary
    /// @dev this function will redeem only a partial amount of tokens based on a redemption timestamp that is in the past. This allows holders to redeem less than their fully unlocked amount for various reasons
    /// @param planIds is the array of the NFT planIds that are to be redeemed. If any have no redeemable balance they will be skipped.
    /// @param redemptionTime is the timestamp which will calculate the amount of tokens redeemable and redeem them based on that timestamp
    function partialRedeemPlans(uint256[] calldata planIds, uint256 redemptionTime) external nonReentrant returns(uint256){
        require(redemptionTime < block.timestamp, "!future");
        return _redeemPlans(planIds, redemptionTime);
    }

    /// @notice this function will redeem all plans owned by a single wallet - useful for custodians or other intermeidaries that do not have the ability to lookup individual planIds
    /// @dev this will iterate through all of the plans owned by the wallet based on the ERC721Enumerable backbone, and redeem each one with a redemption time of the current block.timestamp
    function redeemAllPlans() external nonReentrant returns(uint256){
        uint256 balance = balanceOf(msg.sender);
        uint256[] memory planIds = new uint256[](balance);
        for (uint256 i; i < balance; i++) {
            uint256 planId = tokenOfOwnerByIndex(msg.sender, i);
            planIds[i] = planId;
        }
        return _redeemPlans(planIds, block.timestamp);
    }

    /// @notice function for an owner of a lockup plan to segment a single plan into multiple chunks; segments.
    /// @dev the single plan can be divided up into many segments in this transaction, but care must be taken to ensure that the array is processed in a proper order
    /// if the tokens are send in the wrong order the function will revert becuase the amount of the segment could be larger than the original plan.
    /// this function iterates through the segment amounts and breaks up the same original plan into smaller sizes
    /// each time a segment happens it is always with the single planId, which will generate a new NFT for each new segment, and the original plan is updated in storage
    /// the original plan amount newPlanAmount + segmentAmount && original plan Rate = newPlanRate + segmentRate
    /// @dev Segmenting plans where the segment amount is not divisible by the rate will result in a new End date that is 1 period farther than the original plan
    /// @param planId is the plan that is going to be segmented
    /// @param segmentAmounts is the array of amounts of each individual segment, which must each be smaller than the plan when it is being segmented.
    // function segmentPlan(
    //     uint256 planId,
    //     einput[] memory segmentAmounts,
    //     bytes calldata inputProof
    // ) external nonReentrant returns (uint256[] memory newPlanIds) {
    //     newPlanIds = new uint256[](segmentAmounts.length);
    //     for (uint256 i; i < segmentAmounts.length; i++) {
    //         uint256 newPlanId = _segmentPlan(planId, TFHE.asEuint64(segmentAmounts[i], inputProof));
    //         newPlanIds[i] = newPlanId;
    //     }
    // }

    /// @notice this function combines the functionality of segmenting plans and then immediately delegating the new semgent plans to a delegate address
    /// @dev this function does NOT delegate the original planId at all, it will only delegate the newly create segments
    /// @param planId is the plan that will be segmented (and not delegated)
    /// @param segmentAmounts is the array of each segment amount
    /// @param delegatees is the array of delegatees that each new segment will be delegated to
    // function segmentAndDelegatePlans(
    //     uint256 planId,
    //     einput[] memory segmentAmounts,
    //     address[] memory delegatees,
    //     bytes calldata inputProof
    // ) external nonReentrant returns (uint256[] memory newPlanIds) {
    //     require(segmentAmounts.length == delegatees.length, "length_error");
    //     newPlanIds = new uint256[](segmentAmounts.length);
    //     for (uint256 i; i < segmentAmounts.length; i++) {
    //         uint256 newPlanId = _segmentPlan(planId, TFHE.asEuint64(segmentAmounts[i], inputProof));
    //         _delegateToken(delegatees[i], newPlanId);
    //         newPlanIds[i] = newPlanId;
    //     }
    // }

    /// @notice this function allows a beneficiary of two plans that share the same details to combine them into a single surviving plan
    /// @dev the plans must have the same details except the amount and rate, but must share the same end date to be combined
    /// @param planId0 is the planId of a first plan to be combined
    /// @param planId1 is the planId of a second plan to be combined
    // function combinePlans(uint256 planId0, uint256 planId1) external nonReentrant returns (uint256 survivingPlanId) {
    //     survivingPlanId = _combinePlans(planId0, planId1);
    // }

    /****EXTERNAL VOTING & DELEGATION FUNCTIONS*********************************************************************************************************************************************/
    /// @notice delegation functions do not move any tokens and do not alter any information about the lockup plan object.
    /// the specifically delegate the NFTs using the ERC721Delegate.sol extension.
    /// Use the dedicated snapshot strategy 'hedgey-delegate' to leverage the delegation functions for voting with snapshot

    /// @notice function to delegate an individual NFT tokenId to another wallet address.
    /// @dev by default all plans are self delegated, this allows for the owner of a plan to delegate their NFT to a different address.
    /// This calls the internal _delegateToken function from ERC721Delegate.sol contract
    /// @param planId is the token Id of the NFT and lockup plan to be delegated
    /// @param delegatee is the address that the plan will be delegated to
    function delegate(uint256 planId, address delegatee) external nonReentrant {
        _delegateToken(delegatee, planId);
    }

    /// @notice functeion to delegate multiple plans to multiple delegates in a single transaction
    /// @dev this also calls the internal _delegateToken function from ERC721Delegate.sol to delegate an NFT to another wallet.
    /// @dev this function iterates through the array of plans and delegatees, delegating each individual NFT.
    /// @param planIds is the array of planIds that will be delegated
    /// @param delegatees is the array of addresses that each corresponding planId will be delegated to
    function delegatePlans(uint256[] calldata planIds, address[] calldata delegatees) external nonReentrant {
        require(planIds.length == delegatees.length, "array error");
        for (uint256 i; i < planIds.length; i++) {
            _delegateToken(delegatees[i], planIds[i]);
        }
    }

    /// @notice function to delegate all plans related to a specific token to a single delegatee address
    /// @dev this function pulls the balances of a wallet, checks that the token in the lockup plan matches the token input param, and then delegates it to the delegatee
    /// @param token is the address of the ERC20 tokens that are locked in the lockup plans desired to be delegated
    /// @param delegatee is the address of the delegate that all of the NFTs / plans will be delegated to.
    function delegateAll(address token, address delegatee) external nonReentrant {
        uint256 balance = balanceOf(msg.sender);
        for (uint256 i; i < balance; i++) {
            uint256 planId = tokenOfOwnerByIndex(msg.sender, i);
            if (plans[planId].token == token) _delegateToken(delegatee, planId);
        }
    }

    function transferAndDelegate(uint256 planId, address from, address to) external virtual nonReentrant {
        safeTransferFrom(from, to, planId);
        _transferDelegate(to, planId);
    }

    mapping(uint256 => bool[][]) redeemPlansDecrypted;
    mapping(uint256 => uint256) requestToRedemptionTime;
    mapping(uint256 => uint256[]) requestToRedeemPlanIds;
    mapping(uint256 => euint64[]) requestToRemainder;
    mapping(uint256 => euint64[]) requestToLatestUnlock;
    mapping(uint256 => euint64[]) requestToBalances;

    /****CORE INTERNAL FUNCTIONS*********************************************************************************************************************************************/

    /// @notice function that will intake an array of planIds and a redemption time, and then check the balances that are available to be redeemed
    /// @dev if the nft has an available balance, it is then passed on to the _redeemPlan function for further processing
    /// if there is no balance to be redeemed, the plan is skipped from being processed
    /// @param planIds is the array of plans to be redeemed
    /// @param redemptionTime is the requested redemption time, either the current block.timestamp or a timestamp from the past, but must be greater than the start date
    function _redeemPlans(uint256[] memory planIds, uint256 redemptionTime) internal returns(uint256 requestId){
        require(planIds.length ==3, "not 3 plans");
        euint64[] memory balances = new euint64[](3);
        euint64[] memory remainders = new euint64[](3);
        euint64[] memory latestUnlocks = new euint64[](3);
        uint256[] memory cts = new uint256[](6);

        for (uint256 i; i < 3; i++) {
            (euint64 balance, euint64 remainder, euint64 latestUnlock) = planBalanceOf(
                planIds[i],
                block.timestamp,
                redemptionTime
            );
            balances[i] = balance;
            remainders[i] = remainder;
            latestUnlocks[i] = latestUnlock;

            cts[i] = Gateway.toUint256(TFHE.gt(balance, TFHE.asEuint64(0)));
            cts[i+3] = Gateway.toUint256(TFHE.eq(remainder, TFHE.asEuint64(0)));
            requestId = Gateway.requestDecryption(cts, this.redeemPlansCustomCallback.selector, 0, block.timestamp + 1e4, false);
        }
        requestToRemainder[requestId] = remainders;
        requestToLatestUnlock[requestId] = latestUnlocks;
    }

    function redeemPlansCustomCallback(uint256 requestId, bool cts0, bool cts1, bool cts2, bool cts3, bool cts4, bool cts5) public onlyGateway returns(bool) {
        redeemPlansDecrypted[requestId] = [[cts0, cts1], [cts2, cts3], [cts4, cts5]];
        return true;
    }
    
    function _completeRedeemPlans(uint256 requestId) public {
        for (uint256 i; i < 3; i++) {
            uint256 planId = requestToRedeemPlanIds[requestId][i];
            if (redeemPlansDecrypted[requestId][i][0]) {
                require(ownerOf(planId) == msg.sender, "!owner");
                address token = plans[planId].token;
                if (redeemPlansDecrypted[requestId][i][1]) {
                    delete plans[planId];
                    _burn(planId);
                } else {
                    plans[planId].amount = requestToRemainder[requestId][i];
                    plans[planId].start = requestToLatestUnlock[requestId][i];
                }
                TransferHelper.withdrawTokens(token, msg.sender, requestToBalances[requestId][i]);
                emit PlanRedeemed(planId, requestToBalances[requestId][i], requestToRemainder[requestId][i], requestToLatestUnlock[requestId][i]);
            }
        }
    }

    /// @notice internal function that process the redemption for a single lockup plan
    /// @dev this takes the inputs from the _redeemPlans and processes the redemption delivering the available balance of redeemable tokens to the beneficiary
    /// if the plan is fully redeemed, as defined that the balance == amount, then the plan is deleted and NFT burned
    // if the plan is not fully redeemed, then the storage of start and amount are updated to reflect the remaining amount and most recent time redeemed for the new start date
    /// @param planId is the id of the lockup plan and NFT
    /// @param balance is the available redeemable balance
    /// @param remainder is the amount of tokens that are still lcoked in the plan, and will be the new amount in the plan storage
    /// @param latestUnlock is the most recent timestamp for when redemption occured. Because periods may be longer than 1 second,
    /// the latestUnlock time may be the current block time, or the timestamp of the most recent period timestamp
    // function _redeemPlan(uint256 planId, euint64 balance, euint64 remainder, euint64 latestUnlock) internal {
    //     require(ownerOf(planId) == msg.sender, "!owner");
    //     address token = plans[planId].token;
    //     if (remainder == 0) {
    //         delete plans[planId];
    //         _burn(planId);
    //     } else {
    //         plans[planId].amount = remainder;
    //         plans[planId].start = latestUnlock;
    //     }
    //     TransferHelper.withdrawTokens(token, msg.sender, balance);
    //     emit PlanRedeemed(planId, balance, remainder, latestUnlock);
    // }

    /// @notice the internal function for segmenting a single plan into two
    /// @dev the function takes a plan, performs some checks that the segment amount cannot be 0 and must be strictly less than the original plan amount
    /// then it will subtract the segmentamount from the original plan amount to get the new plan amount
    /// then it will get a new pro-rata rate for the newplan based on the new plan amount divided by the original plan amount
    /// while this pro-rata new rate is not perfect because of unitization (ie no decimal suppport), the segment rate is calculated by subtracting the new plan rate from the original plan rate
    /// because the newplan amount and segment amount == original plan amount, and the new plan rate + segment rate == original plan rate, the beneficiary will still unlock the same number of tokens at approximatley the same rate
    /// however because of uneven division, the end dates of each of the new rates may be different than the original rate. We check to make sure that the new end is farther than the original end
    /// so that tokens do not unlock early, and then it is a valid segment.
    /// finally a new NFT is minted with the Segment plan details
    /// and the storage of the original plan amount and rate is updated with the newplan amount and rate.
    /// @param planId is the id of the lockup plan
    /// @param segmentAmount is the amount of tokens to be segmented off from the original plan and created into a new segment plan
    // function _segmentPlan(uint256 planId, euint64 segmentAmount) internal returns (uint256 newPlanId, ) {
    //     require(ownerOf(planId) == msg.sender, "!owner");
    //     Plan memory plan = plans[planId];
    //     require(segmentAmount < plan.amount, "amount error");
    //     require(segmentAmount > 0, "0_segment");
    //     euint64 end = TimelockLibrary.endDate(plan.start, plan.amount, plan.rate, plan.period);
    //     _planIds.increment();
    //     newPlanId = _planIds.current();
    //     uint256 planAmount = TFHE.sub(plan.amount, segmentAmount);
    //     (uint256 planRate, uint256 segmentRate, uint256 planEnd, uint256 segmentEnd) = TimelockLibrary
    //         .calculateSegmentRates(
    //             plan.rate,
    //             plan.amount,
    //             planAmount,
    //             segmentAmount,
    //             plan.start,
    //             end,
    //             plan.period,
    //             plan.cliff
    //         );
    //     uint256 endCheck = segmentOriginalEnd[planId] == 0 ? end : segmentOriginalEnd[planId];
    //     require(planEnd >= endCheck, "plan end error");
    //     require(segmentEnd >= endCheck, "segmentEnd error");
    //     plans[planId].amount = planAmount;
    //     plans[planId].rate = planRate;
    //     _safeMint(msg.sender, newPlanId);
    //     plans[newPlanId] = Plan(plan.token, segmentAmount, plan.start, plan.cliff, segmentRate, plan.period);
    //     if (segmentOriginalEnd[planId] == 0) {
    //         segmentOriginalEnd[planId] = end;
    //         segmentOriginalEnd[newPlanId] = end;
    //     } else {
    //         segmentOriginalEnd[newPlanId] = segmentOriginalEnd[planId];
    //     }
    //     emit PlanSegmented(
    //         planId,
    //         newPlanId,
    //         planAmount,
    //         planRate,
    //         segmentAmount,
    //         segmentRate,
    //         plan.start,
    //         plan.cliff,
    //         plan.period,
    //         planEnd,
    //         segmentEnd
    //     );
    // }

    /// @notice this funtion allows the holder of two plans that have the same parameters to combine them into a single surviving plan
    /// @dev all of the details of the plans must be the same except the amounts and rates may be different
    /// this function will check that the owners are the same, the ERC20 tokens are the same, the start, cliff and periods are the same.
    /// then it performs some checks on the end dates to ensure that either the end dates are the same, or if the user is combining previously segmented plans,
    /// that the original end dates of those segments are the same.
    /// if everything checks out, and the new end date of the combined plan will result in an end date equal to or later than the two plans, then they can be combined
    /// combining plans will delete the plan1 and burn the NFT related to it
    /// and then update the storage of the plan0 with the combined amount and combined rate
    /// @param planId0 is the planId of the first plan in the combination
    /// @param planId1 is the planId of a second plan to be combined
    // function _combinePlans(uint256 planId0, uint256 planId1) internal returns (uint256 survivingPlan) {
    //     require(planId0 != planId1, "same plan");
    //     require(ownerOf(planId0) == msg.sender, "!owner");
    //     require(ownerOf(planId1) == msg.sender, "!owner");
    //     Plan memory plan0 = plans[planId0];
    //     Plan memory plan1 = plans[planId1];
    //     require(plan0.token == plan1.token, "token error");
    //     require(plan0.start == plan1.start, "start error");
    //     require(plan0.cliff == plan1.cliff, "cliff error");
    //     require(plan0.period == plan1.period, "period error");
    //     euint64 plan0End = TimelockLibrary.endDate(plan0.start, plan0.amount, plan0.rate, plan0.period);
    //     euint64 plan1End = TimelockLibrary.endDate(plan1.start, plan1.amount, plan1.rate, plan1.period);
    //     require(
    //         plan0End == plan1End ||
    //             (segmentOriginalEnd[planId0] == segmentOriginalEnd[planId1] && segmentOriginalEnd[planId0] != 0),
    //         "end error"
    //     );
    //     plans[planId0].amount += plans[planId1].amount;
    //     (uint256 survivorRate, euint64 survivorEnd) = TimelockLibrary.calculateCombinedRate(
    //         TFHE.add(plan0.amount, plan1.amount),
    //         plan0.rate + plan1.rate,
    //         plan0.start,
    //         plan0.period,
    //         plan0End
    //     );
    //     plans[planId0].rate = survivorRate;
    //     if (survivorEnd < plan0End) {
    //         require(
    //             survivorEnd == segmentOriginalEnd[planId0] || survivorEnd == segmentOriginalEnd[planId1],
    //             "original end error"
    //         );
    //     }
    //     delete plans[planId1];
    //     _burn(planId1);
    //     survivingPlan = planId0;
    // }

    /****VIEW VOTING FUNCTIONS*********************************************************************************************************************************************/

    /// @notice this function will pull all of the unclaimed tokens for a specific holder across all of their plans, based on a single ERC20 token
    /// very useful for snapshot voting, and other view functionalities
    /// @param holder is the address of the beneficiary who owns the lockup plan(s)
    /// @param token is the ERC20 address of the token that is stored across the lockup plans
    function lockedBalances(address holder, address token) external view returns (euint64 lockedBalance) {
        uint256 holdersBalance = balanceOf(holder);
        for (uint256 i; i < holdersBalance; i++) {
            uint256 planId = tokenOfOwnerByIndex(holder, i);
            Plan memory plan = plans[planId];
            if (token == plan.token) {
                lockedBalance = TFHE.add(plan.amount, lockedBalance);
            }
        }
    }

    /// @notice this function will pull all of the tokens locked in lockup plans for a specific delegate
    /// this is useful for the snapshot strategy hedgey-delegate, polling this function based on the wallet signed into snapshot
    /// by default all NFTs are self-delegated when they are minted.
    /// @param delegatee is the address of the delegate where NFTs have been delegated to
    /// @param token is the address of the ERC20 token that is locked in lockup plans and has been delegated
    function delegatedBalances(address delegatee, address token) external view returns (euint64 delegatedBalance) {
        uint256 delegateBalance = balanceOfDelegate(delegatee);
        for (uint256 i; i < delegateBalance; i++) {
            uint256 planId = tokenOfDelegateByIndex(delegatee, i);
            Plan memory plan = plans[planId];
            if (token == plan.token) {
                delegatedBalance = TFHE.add(plan.amount, delegatedBalance);
            }
        }
    }
}
