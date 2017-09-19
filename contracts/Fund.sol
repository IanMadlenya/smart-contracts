pragma solidity ^0.4.15;

import {ERC20 as Shares} from './dependencies/ERC20.sol';
import './dependencies/DBC.sol';
import './dependencies/Owned.sol';
import './sphere/SphereInterface.sol';
import './libraries/safeMath.sol';
import './libraries/rewards.sol';
import './participation/ParticipationInterface.sol';
import './datafeeds/DataFeedInterface.sol';
import './riskmgmt/RiskMgmtInterface.sol';
import './exchange/ExchangeInterface.sol';
import './FundInterface.sol';
import './FundHistory.sol';

/// @title Melon Fund Contract
/// @author Melonport AG <team@melonport.com>
/// @notice Simple Melon Fund
contract Fund is DBC, Owned, Shares, FundHistory, FundInterface {
    using safeMath for uint;

    // TYPES

    struct Modules { // List of modular parts, standardized through an interface
        DataFeedInterface datafeed; // Provides all external data
        ExchangeInterface exchange; // Wrapes exchange adapter into exchange interface
        ParticipationInterface participation; // Boolean functions regarding invest/redeem
        RiskMgmtInterface riskmgmt; // Boolean functions regarding make/take orders
    }

    struct Calculations { // List of internal calculations
        uint gav; // Gross asset value
        uint managementReward; // Time based reward
        uint performanceReward; // Performance based reward measured against REFERENCE_ASSET
        uint unclaimedRewards; // Rewards not yet allocated to fund manager
        uint nav; // Net asset value
        uint sharePrice; // A measure of fund performance
        uint totalSupply; // Total supply of shares
        uint timestamp; // When above has been calculated
    }

    // FIELDS

    // Constant fields
    string constant SYMBOL = "MLN-Fund"; // Melon Fund
    uint constant DECIMALS = 18; // Amount of deciamls sharePrice is denominated in
    uint constant VAULT_BASE_UNITS = 10 ** DECIMALS; // One unit of share equals 10 ** DECIMALS of base unit of shares
    uint public constant DIVISOR_FEE = 10 ** 15; // Reward are divided by this number
    uint public constant MAX_OPEN_ORDERS = 6; // Maximum number of open orders
    // Constructor fields
    string public NAME; // Name of this fund
    uint public CREATED; // Timestamp of Fund creation
    uint public MELON_BASE_UNITS; // One unit of share equals 10 ** DECIMALS of base unit of shares
    uint public MANAGEMENT_REWARD_RATE; // Reward rate in REFERENCE_ASSET per delta improvment
    uint public PERFORMANCE_REWARD_RATE; // Reward rate in REFERENCE_ASSET per managed seconds
    address public VERSION; // Address of Version contract
    address public EXCHANGE; // Other then redeem, assets can only be transferred to this, eg to an exchange
    address public MELON_ASSET; // Address of Melon asset contract
    ERC20 public MELON_CONTRACT; // Melon as ERC20 contract
    address public REFERENCE_ASSET; // Performance measured against value of this asset
    // Function fields
    uint[] openOrderIds = new uint[](MAX_OPEN_ORDERS);
    mapping (address => uint) public previousHoldings;
    Modules public module;
    Calculations public atLastConversion;
    bool public isShutDown;
    bool public isSubscribeAllowed;
    bool public isRedeemAllowed;

    // PRE, POST, INVARIANT CONDITIONS

    function isZero(uint x) internal returns (bool) { return 0 == x; }
    function isPastZero(uint x) internal returns (bool) { return 0 < x; }
    function notLessThan(uint x, uint y) internal returns (bool) { return x >= y; }
    function notGreaterThan(uint x, uint y) internal returns (bool) { return x <= y; }
    function isLargerThan(uint x, uint y) internal returns (bool) { return x > y; }
    function isLessThan(uint x, uint y) internal returns (bool) { return x < y; }
    function isEqualTo(uint x, uint y) internal returns (bool) { return x == y; }
    function isSubscribe(RequestType x) internal returns (bool) { return x == RequestType.subscribe; }
    function isRedeem(RequestType x) internal returns (bool) { return x == RequestType.redeem; }
    function notShutDown() internal returns (bool) { return !isShutDown; }
    /// @dev Pre: Transferred tokens to this contract
    /// @dev Post Approved to spend tokens on EXCHANGE
    function approveSpending(address onConsigned, address ofAsset, uint quantity)
        /*internal*/
        returns (bool success)
    {
        success = ERC20(ofAsset).approve(onConsigned, quantity);
        SpendingApproved(onConsigned, ofAsset, quantity);
    }
    function noOpenOrders() internal returns (bool) { return nextOpenSlotOfArray() == 0; }
    function openOrdersNotFull() internal returns (bool) { return nextOpenSlotOfArray() == MAX_OPEN_ORDERS; }
    function balancesOfHolderAtLeast(address ofHolder, uint x) internal returns (bool) { return balances[ofHolder] >= x; }
    function isVersion() internal returns (bool) { return msg.sender == VERSION; }

    // INTERNAL METHODS

    function nextOpenSlotOfArray() internal returns (uint) {
        for (uint i = 0; i < openOrderIds.length; i++) {
            if (openOrderIds[i] != 0) return i;
        }
        return MAX_OPEN_ORDERS;
    }
    function getIntendedSellQuantity(address ofAsset) internal returns(uint amount) {
        for (uint i = 0; i < openOrderIds.length; i++) {
            Order thisOrder = orders[openOrderIds[i]];
            if (thisOrder.sellAsset == ofAsset) {
                amount = amount + thisOrder.sellQuantity;
            }
        }
    }
    function getIntendedBuyQuantity(address ofAsset) internal returns(uint amount) {
        for (uint i = 0; i < openOrderIds.length; i++) {
            Order thisOrder = orders[openOrderIds[i]];
            if (thisOrder.buyAsset == ofAsset) {
                amount = amount + thisOrder.buyQuantity;
            }
        }
    }

    // CONSTANT METHODS

    function getName() constant returns (string) { return NAME; }
    function getSymbol() constant returns (string) { return SYMBOL; }
    function getDecimals() constant returns (uint) { return DECIMALS; }
    function getModules() constant returns (address ,address, address, address) {
        return (
            address(module.datafeed),
            address(module.exchange),
            address(module.participation),
            address(module.riskmgmt)
        );
    }
    function getStake() constant returns (uint) { return balanceOf(this); }

    // CONSTANT METHODS - ACCOUNTING

    /// @dev Pre: Decimals in assets must be equal to decimals in PriceFeed for all entries in Universe
    /// @dev Post Gross asset value denominated in [base unit of melonAsset]
    function calcGav() constant returns (uint gav) {
        for (uint i = 0; i < module.datafeed.numRegisteredAssets(); ++i) {
            address ofAsset = address(module.datafeed.getRegisteredAssetAt(i));
            uint assetHoldings = uint(ERC20(ofAsset).balanceOf(this)) // Amount of asset base units this vault holds
                .add(ERC20(ofAsset).balanceOf(EXCHANGE)); // Qty held in custody
            uint assetPrice = module.datafeed.getPrice(ofAsset);
            uint assetDecimals = module.datafeed.getDecimals(ofAsset);
            gav = gav.add(assetHoldings.mul(assetPrice).div(10 ** uint(assetDecimals))); // Sum up product of asset holdings of this vault and asset prices
            PortfolioContent(assetHoldings, assetPrice, assetDecimals);
        }
    }

    /// @dev Pre: Gross asset value has been calculated
    /// @dev Post The sum and its individual parts of all applicable fees denominated in [base unit of melonAsset]
    function calcUnclaimedRewards(uint gav)
        constant
        returns (
            uint managementReward,
            uint performanceReward,
            uint unclaimedRewards
        )
    {
        uint timeDifference = now.sub(atLastConversion.timestamp);
        managementReward = rewards.managementReward(
            MANAGEMENT_REWARD_RATE,
            timeDifference,
            gav,
            DIVISOR_FEE
        );
        performanceReward = 0;
        if (totalSupply != 0) {
            uint currSharePrice = calcValuePerShare(gav); // TODO Multiply w getInvertedPrice(ofReferenceAsset)
            if (currSharePrice > atLastConversion.sharePrice) {
              performanceReward = rewards.performanceReward(
                  PERFORMANCE_REWARD_RATE,
                  int(currSharePrice - atLastConversion.sharePrice),
                  totalSupply,
                  DIVISOR_FEE
              );
            }
        }
        unclaimedRewards = managementReward.add(performanceReward);
    }

    /// @dev Pre: Gross asset value and sum of all applicable and unclaimed fees has been calculated
    /// @dev Post Net asset value denominated in [base unit of melonAsset]
    function calcNav(uint gav, uint unclaimedRewards)
        constant
        returns (uint nav)
    {
        nav = gav.sub(unclaimedRewards);
    }

    /// @dev Pre: Non-zero share supply; value denominated in [base unit of melonAsset]
    /// @dev Post Share price denominated in [base unit of melonAsset * base unit of share / base unit of share] == [base unit of melonAsset]
    function calcValuePerShare(uint value)
        constant
        pre_cond(isPastZero(totalSupply))
        returns (uint valuePerShare)
    {
        valuePerShare = value.mul(MELON_BASE_UNITS).div(totalSupply);
    }

    /// @dev Pre: None
    /// @dev Post Gav, managementReward, performanceReward, unclaimedRewards, nav, sharePrice denominated in [base unit of melonAsset]
    function performCalculations() constant returns (uint, uint, uint, uint, uint, uint) {
        uint gav = calcGav(); // Reflects value indepentent of fees
        var (managementReward, performanceReward, unclaimedRewards) = calcUnclaimedRewards(gav);
        uint nav = calcNav(gav, unclaimedRewards);
        uint sharePrice = isPastZero(totalSupply) ? calcValuePerShare(nav) : MELON_BASE_UNITS; // Handle potential division through zero by defining a default value
        return (gav, managementReward, performanceReward, unclaimedRewards, nav, sharePrice);
    }

    /// @dev Pre: None
    /// @dev Post sharePrice denominated in [base unit of melonAsset]
    function calcSharePrice() constant returns (uint)
    {
        var (, , , , , sharePrice) = performCalculations();
        return sharePrice;
    }

    // NON-CONSTANT METHODS

    function Fund(
        address ofManager,
        string withName,
        string withSymbol, // TODO remove
        uint withDecimals, // TODO remove
        uint ofManagementRewardRate,
        uint ofPerformanceRewardRate,
        address ofMelonAsset,
        address ofParticipation,
        address ofRiskMgmt,
        address ofSphere
    ) {
        SphereInterface sphere = SphereInterface(ofSphere);
        module.exchange = ExchangeInterface(sphere.getExchangeAdapter()); // Bridge thrid party exchange to Melon exchange interface
        module.datafeed = DataFeedInterface(sphere.getDataFeed());
        isSubscribeAllowed = true;
        isRedeemAllowed = true;
        owner = ofManager;
        NAME = withName;
        MANAGEMENT_REWARD_RATE = ofManagementRewardRate;
        PERFORMANCE_REWARD_RATE = ofPerformanceRewardRate;
        VERSION = msg.sender;
        EXCHANGE = address(sphere.getExchange()); // Actual exchange Address
        MELON_ASSET = ofMelonAsset;
        REFERENCE_ASSET = MELON_ASSET; // XXX let user decide
        MELON_CONTRACT = ERC20(MELON_ASSET);
        require(MELON_ASSET == module.datafeed.getQuoteAsset()); // Sanity check
        MELON_BASE_UNITS = 10 ** uint(module.datafeed.getDecimals(MELON_ASSET));
        module.participation = ParticipationInterface(ofParticipation);
        module.riskmgmt = RiskMgmtInterface(ofRiskMgmt);
        atLastConversion = Calculations({
            gav: 0,
            managementReward: 0,
            performanceReward: 0,
            unclaimedRewards: 0,
            nav: 0,
            sharePrice: MELON_BASE_UNITS,
            totalSupply: totalSupply,
            timestamp: now
        });
        CREATED = now;
    }

    // NON-CONSTANT METHODS - ADMINISTRATION

    function increaseStake(uint numShares)
        external
        pre_cond(isOwner())
        pre_cond(isPastZero(numShares))
        pre_cond(notShutDown())
        pre_cond(balancesOfHolderAtLeast(msg.sender, numShares))
        pre_cond(noOpenOrders())
        post_cond(prevTotalSupply == totalSupply)
    {
        uint prevTotalSupply = totalSupply;
        subShares(msg.sender, numShares);
        addShares(this, numShares);
    }

    function decreaseStake(uint numShares)
        external
        pre_cond(isOwner())
        pre_cond(isPastZero(numShares))
        pre_cond(notShutDown())
        pre_cond(balancesOfHolderAtLeast(this, numShares))
        pre_cond(noOpenOrders())
        post_cond(prevTotalSupply == totalSupply)
    {
        uint prevTotalSupply = totalSupply;
        subShares(this, numShares);
        addShares(msg.sender, numShares);
    }

    function toogleSubscription()
        external
        pre_cond(isOwner())
    {
        isSubscribeAllowed = !isSubscribeAllowed;
    }

    function toggleRedemption()
        external
        pre_cond(isOwner())
    {
        isRedeemAllowed = !isRedeemAllowed;
    }

    function shutDown()
        pre_cond(isVersion() || isOwner())
    {
        isShutDown = true;
    }

    // NON-CONSTANT METHODS - PARTICIPATION

    /// @dev Pre: offeredValue denominated in [base unit of MELON_ASSET]
    /// @dev Pre: Amount of shares for offered value; Non-zero incentive Value which is paid to workers
    /// @dev Post Pending subscription Request
    function requestSubscription(
        uint numShares,
        uint offeredValue,
        uint incentiveValue
    )
        external
        pre_cond(notShutDown())
        pre_cond(isSubscribeAllowed)
        pre_cond(isPastZero(incentiveValue))
        pre_cond(module.datafeed.isValid(MELON_ASSET))
        pre_cond(module.participation.isSubscriptionPermitted(
            msg.sender,
            numShares,
            offeredValue
        ))
        returns(uint id)
    {
        MELON_CONTRACT.transferFrom(msg.sender, this, offeredValue);
        id = nextRequestId;
        nextRequestId++;
        requests[id] = Request({
            owner: msg.sender,
            status: RequestStatus.open,
            requestType: RequestType.subscribe,
            numShares: numShares,
            offeredOrRequestedValue: offeredValue,
            incentive: incentiveValue,
            lastFeedUpdateId: module.datafeed.getLastUpdateId(),
            lastFeedUpdateTime: module.datafeed.getLastUpdateTimestamp(),
            timestamp: now
        });
        SubscribeRequest(id, msg.sender, now, numShares);
    }

    /// @dev Pre:  Redeemer has at least `numShares` shares; redeemer approved this contract to handle shares
    /// @dev Post Redeemer lost `numShares`, and gained `numShares * value` reference tokens
    function requestRedemption(
        uint numShares,
        uint requestedValue,
        uint incentiveValue
      )
        external
        pre_cond(notShutDown())
        pre_cond(isRedeemAllowed)
        pre_cond(isPastZero(numShares))
        pre_cond(module.participation.isRedemptionPermitted(
            msg.sender,
            numShares,
            requestedValue
        ))
        returns (uint id)
    {
        id = nextRequestId;
        nextRequestId++;
        requests[id] = Request({
            owner: msg.sender,
            status: RequestStatus.open,
            requestType: RequestType.redeem,
            numShares: numShares,
            offeredOrRequestedValue: requestedValue,
            incentive: incentiveValue,
            lastFeedUpdateId: module.datafeed.getLastUpdateId(),
            lastFeedUpdateTime: module.datafeed.getLastUpdateTimestamp(),
            timestamp: now
        });
        RedeemRequest(id, msg.sender, now, numShares);
    }

    /// @dev Pre: Anyone can trigger this function; Id of request that is pending
    /// @dev Post Worker either cancelled or fullfilled request
    function executeRequest(uint requestId)
        external
        pre_cond(notShutDown())
        pre_cond(isSubscribe(requests[requestId].requestType) ||
            isRedeem(requests[requestId].requestType))
        pre_cond(notLessThan(
            now,
            requests[requestId].timestamp.add(module.datafeed.getInterval())
        ))
        pre_cond(notLessThan(
            module.datafeed.getLastUpdateId(),
            requests[requestId].lastFeedUpdateId + 2
        ))
    {
        // Time and updates have passed
        Request request = requests[requestId];
        uint actualValue = request.numShares.mul(calcSharePrice()).div(VAULT_BASE_UNITS); // denominated in [base unit of MELON_ASSET]
        request.status = RequestStatus.executed;
        if (isSubscribe(requests[requestId].requestType) &&
            notLessThan(request.offeredOrRequestedValue, actualValue) // Sanity Check
        ) { // Limit Order is OK
            assert(MELON_CONTRACT.transferFrom(request.owner, msg.sender, request.incentive)); // Reward Worker
            uint remainder = request.offeredOrRequestedValue.sub(actualValue);
            if(remainder > 0) assert(MELON_CONTRACT.transfer(request.owner, remainder)); // Return remainder
            createShares(request.owner, request.numShares); // Accounting
        } else if (isRedeem(requests[requestId].requestType) &&
            notGreaterThan(request.offeredOrRequestedValue, actualValue) // Sanity Check
        ) {
            assert(MELON_CONTRACT.transferFrom(request.owner, msg.sender, request.incentive)); // Reward Worker
            assert(MELON_CONTRACT.transfer(request.owner, actualValue)); // Transfer value
            annihilateShares(request.owner, request.numShares); // Accounting
        }
    }

    function cancelRequest(uint requestId)
        external
        pre_cond(isSubscribe(requests[requestId].requestType) ||
            isRedeem(requests[requestId].requestType)) // TODO: Check validity of this
        pre_cond(requests[requestId].owner == msg.sender || isShutDown)
    {
        Request request = requests[requestId];
        request.status = RequestStatus.cancelled;
        assert(MELON_CONTRACT.transfer(msg.sender, request.incentive));
        assert(MELON_CONTRACT.transfer(request.owner, request.offeredOrRequestedValue));
    }

    /// @dev Pre: Recipient owns shares
    /// @dev Post Transfer percentage of all assets from Fund to Investor and annihilate numShares of shares.
    /// Note: Independent of running price feed!
    function redeemUsingSlice(uint numShares)
        external
        pre_cond(balancesOfHolderAtLeast(msg.sender, numShares))
    {
        // Current Value
        uint prevTotalSupply = totalSupply.sub(atLastConversion.unclaimedRewards); // TODO Fix calculation
        assert(isPastZero(prevTotalSupply));
        annihilateShares(msg.sender, numShares); // Destroy _before_ external calls to prevent reentrancy
        // Transfer ownershipQty of Assets
        for (uint i = 0; i < module.datafeed.numRegisteredAssets(); ++i) {
            address ofAsset = address(module.datafeed.getRegisteredAssetAt(i));
            uint assetHoldings = ERC20(ofAsset).balanceOf(this);
            if (assetHoldings == 0) continue;
            uint ownershipQty = assetHoldings.mul(numShares).div(prevTotalSupply); // ownership percentage of msg.sender
            if (isLessThan(ownershipQty, assetHoldings)) { // Less available than what is owned
                isShutDown = true; // Eg in case of unreturned qty at EXCHANGE address
            }
            assert(ERC20(ofAsset).transfer(msg.sender, ownershipQty)); // Send funds from vault to investor
        }
        Redeemed(msg.sender, now, numShares);
    }

    function createShares(address recipient, uint numShares) internal {
        totalSupply = totalSupply.add(numShares);
        addShares(recipient, numShares);
        Subscribed(msg.sender, now, numShares);
    }

    function annihilateShares(address recipient, uint numShares) internal {
        totalSupply = totalSupply.sub(numShares);
        subShares(recipient, numShares);
        Redeemed(msg.sender, now, numShares);
    }

    function addShares(address recipient, uint numShares) internal {
        balances[recipient] = balances[recipient].add(numShares);
    }

    function subShares(address recipient, uint numShares) internal {
        balances[recipient] = balances[recipient].sub(numShares);
    }

    // NON-CONSTANT METHODS - MANAGING

    /// @notice These are orders that are not expected to settle immediately
    /// @dev Pre: Sufficient balance and spending has been approved
    /// @dev Post Make offer on selected Exchange
    function makeOrder(
        address sellAsset,
        address buyAsset,
        uint sellQuantity,
        uint buyQuantity
    )
        external
        pre_cond(isOwner())
        pre_cond(notShutDown())
        pre_cond(module.datafeed.existsData(sellAsset, buyAsset))
        pre_cond(module.riskmgmt.isMakePermitted(
            module.datafeed.getOrderPrice(
                sellQuantity,
                buyQuantity
            ),
            buyQuantity, // Quantity trying to be received
            module.datafeed.getReferencePrice(sellAsset, buyAsset)
        ))
        returns (uint id)
    {
        require(approveSpending(EXCHANGE, sellAsset, sellQuantity));
        address(module.exchange).delegatecall( // TODO: use as library call
            bytes4(sha3("makeOrder(address,address,address,uint256,uint256)")),
            EXCHANGE, sellAsset, buyAsset, sellQuantity, buyQuantity
        ); // TODO check boolean return value
        /*id = module.exchange.makeOrder(sellAsset, buyAsset, sellQuantity, buyQuantity);*/
        orders[nextOrderId] = Order({
            sellAsset: sellAsset,
            buyAsset: buyAsset,
            sellQuantity: sellQuantity,
            buyQuantity: buyQuantity,
            timestamp: now,
            status: OrderStatus.open,
            orderType: OrderType.make,
            fillQuantity: 0
        });
        // TODO count open orders as integer
        nextOrderId++;
    }

    /// @notice These are orders that are expected to settle immediately
    /// @dev Pre: Active offer (id) and valid buy amount on selected Exchange
    /// @dev Post Take offer on selected Exchange
    function takeOrder(uint id, uint quantity)
        external
        pre_cond(isOwner())
        pre_cond(notShutDown())
        returns (bool)
    {
        // Inverse variable terminology! Buying what another person is selling
        Order memory order;
        (
            order.sellAsset,
            order.buyAsset,
            order.sellQuantity,
            order.buyQuantity
        ) = module.exchange.getOrder(EXCHANGE, id);
        require(module.datafeed.existsData(order.buyAsset, order.sellAsset));
        require(quantity <= order.sellQuantity);
        require(module.riskmgmt.isTakePermitted(
            module.datafeed.getOrderPrice(
                order.buyQuantity, // Buying what is being sold
                order.sellQuantity // Selling what is being bhought
            ),
            order.sellQuantity, // Quantity about to be received
            module.datafeed.getReferencePrice(order.buyAsset, order.sellAsset)
        ));
        require(approveSpending(EXCHANGE, order.buyAsset, quantity));
        bool success = address(module.exchange).delegatecall( // TODO: use as library call
            bytes4(sha3("takeOrder(address,uint256,uint256)")),
            EXCHANGE, id, quantity
        );
        order.timestamp = now;
        order.status = OrderStatus.fullyFilled;
        order.orderType = OrderType.take;
        order.fillQuantity = quantity;
        orders[nextOrderId] = order;
        nextOrderId++;
        return success;
    }

    /// @dev Pre: Active offer (id) with owner of this contract on selected Exchange
    /// @dev Post Cancel offer on selected Exchange
    function cancelOrder(uint id)
        external
        pre_cond(isOwner() || isShutDown)
        returns (bool)
    {
        // TODO orders accounting
        return module.exchange.cancelOrder(EXCHANGE, id);
    }

    //TODO: add previousHoldings
    function closeOpenOrders(address ofBase, address ofQuote)
        constant
    {
        for (uint i = 0; i < openOrderIds.length; i++) {
            Order thisOrder = orders[openOrderIds[i]];
            if (thisOrder.sellAsset == ofBase && thisOrder.buyAsset == ofQuote) {
                proofOfEmbezzlement(ofBase, ofQuote);
                delete openOrderIds[i]; // Free up open order slot
                // TODO: fix pot incorrect OrderStatus - partiallyFilled
                thisOrder.status = OrderStatus.fullyFilled;
                //  update previousHoldings
                // TODO: trigger for each proofOfEmbezzlement() call
                previousHoldings[ofBase] = ERC20(ofBase).balanceOf(this);
                previousHoldings[ofQuote] = ERC20(ofQuote).balanceOf(this);
            }
        }
    }

    /// @notice Whether embezzlement happened
    /// @dev Pre: Specific asset pair (ofBase.ofQuote) where by convention ofBase is asset being sold and ofQuote asset being bhought
    /// @dev Post True if embezzled otherwise false
    function proofOfEmbezzlement(address ofBase, address ofQuote)
        constant
        returns (bool)
    {
        // Sold more than expected => Proof of Embezzlemnt
        uint totalIntendedSellQty = getIntendedSellQuantity(ofBase); // Trade intention
        if (isLargerThan(
            previousHoldings[ofBase].sub(totalIntendedSellQty), // Intended amount sold
            ERC20(ofBase).balanceOf(this) // Actual amount sold
        )) {
            isShutDown = true;
            // TODO: Allocate staked shares from this to msg.sender
            return true;
        }
        // Sold less or equal than intended
        uint factor = 10000;
        uint divisor = factor;
        if (isLessThan(
            previousHoldings[ofBase].sub(totalIntendedSellQty), // Intended amount sold
            ERC20(ofBase).balanceOf(this) // Actual amount sold
        )) { // Sold less than intended
            factor = divisor
                .mul(previousHoldings[ofBase].sub(ERC20(ofBase).balanceOf(this)))
                .div(totalIntendedSellQty);
        }
        // Sold at a worse price than expected => Proof of Embezzlemnt
        uint totalIntendedBuyQty = getIntendedBuyQuantity(ofQuote); // Trade execution
        uint totalExpectedBuyQty = totalIntendedBuyQty.mul(factor).div(divisor);
        if (isLargerThan(
            previousHoldings[ofQuote].add(totalExpectedBuyQty), // Expected amount bhought
            ERC20(ofQuote).balanceOf(this) // Actual amount sold
        )) {
            isShutDown = true;
            // TODO: Allocate staked shares from this to msg.sender
            return true;
        }
        return false;
    }

    // NON-CONSTANT METHODS - REWARDS

    /// @dev Pre: Only Owner
    /// @dev Post Unclaimed fees of manager are converted into shares of the Owner of this fund.
    function convertUnclaimedRewards()
        external
        pre_cond(isOwner())
        pre_cond(notShutDown())
        pre_cond(noOpenOrders())
    {
        var (
            gav,
            managementReward,
            performanceReward,
            unclaimedRewards,
            nav,
            sharePrice
        ) = performCalculations();
        assert(isPastZero(gav));

        // Accounting: Allocate unclaimedRewards to this fund
        uint numShares = totalSupply.mul(unclaimedRewards).div(gav);
        addShares(owner, numShares);
        // Update Calculations
        atLastConversion = Calculations({
            gav: gav,
            managementReward: managementReward,
            performanceReward: performanceReward,
            unclaimedRewards: unclaimedRewards,
            nav: nav,
            sharePrice: sharePrice,
            totalSupply: totalSupply,
            timestamp: now
        });

        RewardsConverted(now, numShares, unclaimedRewards);
        CalculationUpdate(now, managementReward, performanceReward, nav, sharePrice, totalSupply);
    }
}