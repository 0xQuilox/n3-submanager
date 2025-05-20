// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SubscriptionManager is AccessControl, Pausable, ReentrancyGuard {
    IERC20 public usdcToken;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant REFUND_WINDOW = 1 days;

    struct Subscription {
        bool isActive;
        uint256 expiryTime;
        uint256 planId;
        uint256 planVersion;
        uint256 startTime;
        bool autoRenew;
    }

    struct Plan {
        uint256 price;
        uint256 duration;
        uint256 trialDuration;
        bool isActive;
        string benefits;
        uint256 version;
    }

    mapping(address => Subscription) public subscriptions;
    mapping(uint256 => Plan) public plans;
    uint256 public planCount;

    event SubscriptionPurchased(
        address indexed user,
        uint256 planId,
        uint256 expiryTime,
        uint256 amount,
        uint256 duration,
        uint256 planVersion
    );
    event SubscriptionCancelled(address indexed user);
    event SubscriptionRefunded(address indexed user, uint256 amount);
    event SubscriptionRenewed(address indexed user, uint256 planId, uint256 expiryTime);
    event PlanAdded(uint256 indexed planId, uint256 price, uint256 duration, string benefits, uint256 version);
    event PlanUpdated(uint256 indexed planId, uint256 price, uint256 duration, string benefits, uint256 version);
    event PlanDeactivated(uint256 indexed planId);
    event FundsWithdrawn(address indexed recipient, uint256 amount);
    event AutoRenewToggled(address indexed user, bool enabled);

    constructor(address _usdcToken, address defaultAdmin) {
        require(_usdcToken != address(0), "Invalid USDC token address");
        require(defaultAdmin != address(0), "Invalid admin address");
        usdcToken = IERC20(_usdcToken);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(ADMIN_ROLE, defaultAdmin);
        _grantRole(TREASURY_ROLE, defaultAdmin);
    }

    function purchaseSubscription(uint256 planId) external nonReentrant whenNotPaused {
        Plan memory plan = plans[planId];
        require(plan.isActive && plan.price > 0 && plan.duration > 0, "Invalid plan");
        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        require(usdcToken.transferFrom(msg.sender, address(this), plan.price), "USDC transfer failed");
        require(
            usdcToken.balanceOf(address(this)) - balanceBefore >= plan.price,
            "Received amount less than price"
        );
        Subscription storage userSub = subscriptions[msg.sender];
        uint256 newExpiryTime = userSub.isActive && userSub.expiryTime > block.timestamp
            ? userSub.expiryTime + plan.duration
            : block.timestamp + plan.duration;
        userSub.isActive = true;
        userSub.expiryTime = newExpiryTime;
        userSub.planId = planId;
        userSub.planVersion = plan.version;
        userSub.startTime = block.timestamp;
        emit SubscriptionPurchased(msg.sender, planId, newExpiryTime, plan.price, plan.duration, plan.version);
    }

    function startTrial(uint256 planId) external nonReentrant whenNotPaused {
        Plan memory plan = plans[planId];
        require(plan.isActive && plan.trialDuration > 0, "No trial available");
        Subscription storage userSub = subscriptions[msg.sender];
        require(!userSub.isActive, "Already subscribed");
        userSub.isActive = true;
        userSub.expiryTime = block.timestamp + plan.trialDuration;
        userSub.planId = planId;
        userSub.planVersion = plan.version;
        userSub.startTime = block.timestamp;
        emit SubscriptionPurchased(msg.sender, planId, userSub.expiryTime, 0, plan.trialDuration, plan.version);
    }

    function changePlan(uint256 newPlanId) external nonReentrant whenNotPaused {
        Subscription storage userSub = subscriptions[msg.sender];
        require(userSub.isActive && userSub.expiryTime > block.timestamp, "No active subscription");
        Plan memory newPlan = plans[newPlanId];
        require(newPlan.isActive && newPlan.price > 0 && newPlan.duration > 0, "Invalid new plan");
        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        require(usdcToken.transferFrom(msg.sender, address(this), newPlan.price), "USDC transfer failed");
        require(
            usdcToken.balanceOf(address(this)) - balanceBefore >= newPlan.price,
            "Received amount less than price"
        );
        userSub.planId = newPlanId;
        userSub.planVersion = newPlan.version;
        userSub.expiryTime = block.timestamp + newPlan.duration;
        userSub.startTime = block.timestamp;
        emit SubscriptionPurchased(msg.sender, newPlanId, userSub.expiryTime, newPlan.price, newPlan.duration, newPlan.version);
    }

    function cancelSubscription() external {
        Subscription storage userSub = subscriptions[msg.sender];
        require(userSub.isActive, "No active subscription");
        userSub.isActive = false;
        userSub.expiryTime = 0;
        userSub.planId = 0;
        userSub.planVersion = 0;
        userSub.startTime = 0;
        userSub.autoRenew = false;
        emit SubscriptionCancelled(msg.sender);
    }

    function refundSubscription() external nonReentrant {
        Subscription storage userSub = subscriptions[msg.sender];
        require(userSub.isActive, "No active subscription");
        require(block.timestamp <= userSub.startTime + REFUND_WINDOW, "Refund window expired");
        Plan memory plan = plans[userSub.planId];
        require(plan.price > 0, "No payment to refund");
        userSub.isActive = false;
        userSub.expiryTime = 0;
        userSub.planId = 0;
        userSub.planVersion = 0;
        userSub.startTime = 0;
        userSub.autoRenew = false;
        bool success = usdcToken.transfer(msg.sender, plan.price);
        require(success, "Refund transfer failed");
        emit SubscriptionRefunded(msg.sender, plan.price);
    }

    function toggleAutoRenew() external {
        Subscription storage userSub = subscriptions[msg.sender];
        userSub.autoRenew = !userSub.autoRenew;
        emit AutoRenewToggled(msg.sender, userSub.autoRenew);
    }

    function batchProcessRenewals(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            Subscription storage userSub = subscriptions[users[i]];
            if (
                userSub.isActive &&
                userSub.autoRenew &&
                block.timestamp >= userSub.expiryTime &&
                plans[userSub.planId].isActive
            ) {
                Plan memory plan = plans[userSub.planId];
                uint256 balanceBefore = usdcToken.balanceOf(address(this));
                bool success = usdcToken.transferFrom(users[i], address(this), plan.price);
                if (
                    success &&
                    usdcToken.balanceOf(address(this)) - balanceBefore >= plan.price
                ) {
                    userSub.expiryTime += plan.duration;
                    userSub.startTime = block.timestamp;
                    emit SubscriptionRenewed(users[i], userSub.planId, userSub.expiryTime);
                }
            }
        }
    }

    function getSubscription(address user)
        external
        view
        returns (bool isActive, uint256 expiryTime, uint256 planId, uint256 planVersion)
    {
        Subscription memory userSub = subscriptions[user];
        bool active = userSub.isActive && userSub.expiryTime > block.timestamp;
        return (active, userSub.expiryTime, userSub.planId, userSub.planVersion);
    }

    function addPlan(
        uint256 price,
        uint256 duration,
        uint256 trialDuration,
        string calldata benefits
    ) external onlyRole(ADMIN_ROLE) {
        require(price > 0 || trialDuration > 0, "Price or trial required");
        require(duration > 0 && duration <= MAX_DURATION, "Duration out of bounds");
        require(trialDuration <= duration, "Trial exceeds duration");
        require(bytes(benefits).length <= 100, "Benefits too long");
        planCount++;
        plans[planCount] = Plan({
            price: price,
            duration: duration,
            trialDuration: trialDuration,
            isActive: true,
            benefits: benefits,
            version: 1
        });
        emit PlanAdded(planCount, price, duration, benefits, 1);
    }

    function updatePlan(
        uint256 planId,
        uint256 price,
        uint256 duration,
        uint256 trialDuration,
        string calldata benefits
    ) external onlyRole(ADMIN_ROLE) {
        Plan storage plan = plans[planId];
        require(plan.isActive, "Plan does not exist or is inactive");
        require(price > 0 || trialDuration > 0, "Price or trial required");
        require(duration > 0 && duration <= MAX_DURATION, "Duration out of bounds");
        require(trialDuration <= duration, "Trial exceeds duration");
        require(bytes(benefits).length <= 100, "Benefits too long");
        plan.price = price;
        plan.duration = duration;
        plan.trialDuration = trialDuration;
        plan.benefits = benefits;
        plan.version += 1;
        emit PlanUpdated(planId, price, duration, benefits, plan.version);
    }

    function deactivatePlan(uint256 planId) external onlyRole(ADMIN_ROLE) {
        require(plans[planId].isActive, "Plan does not exist or is inactive");
        plans[planId].isActive = false;
        emit PlanDeactivated(planId);
    }

    function withdrawFunds(address recipient, uint256 amount)
        external
        onlyRole(TREASURY_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(recipient != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than 0");
        require(usdcToken.balanceOf(address(this)) >= amount, "Insufficient balance");
        bool success = usdcToken.transfer(recipient, amount);
        require(success, "USDC transfer failed");
        emit FundsWithdrawn(recipient, amount);
    }
}