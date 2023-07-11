// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {IWAVAX} from "../../interfaces/IWAVAX.sol";
import {IGReservePool} from "../../interfaces/IGReservePool.sol";
import {IGLendingPool} from "../../interfaces/IGLendingPool.sol";
import {AccessControlManager} from "../../AccessControlManager.sol";
import {GlacierAddressBook} from "../../GlacierAddressBook.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title  Interest bearing ERC-20 token implementation
 * @author Jack Frost
 * @notice Glacial AVAX (glAVAX) is an AVAX derivative ERC-20 token that represents AVAX deposited into the Glacier protocol.
 *
 * Users can mint glAVAX by depositing AVAX at a 1:1 rate, where the contract will give the user shares of the overall network depending on their
 * proportion of AVAX against the proportion of overall AVAX.
 *
 * Users can then redeem back their AVAX at a 1:1 rate for the balance of their glAVAX.
 *
 * glAVAX balances are rebased automatically by the network to include all accrued rewards from deposits.
 */
contract glAVAX is
    Initializable,
    IERC20Upgradeable,
    AccessControlManager,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Math for uint256;

    /// @notice Token Info
    string private constant NAME = "Glacial AVAX";
    string private constant SYMBOL = "glAVAX";
    uint8 private constant DECIMALS = 18;

    /// @notice minimun liquidity stay in the contract
    uint256 public constant MINIMUM_LIQUIDITY = 1e3;

    /// @notice The percentage precision of reservePercentage
    uint256 public constant PERCENTAGE_PRECISION = 1e4;

    /// @notice The underlying share balances for user deposits
    /// @dev These act as a way to calculate how much AVAX a user has a claim to in the network
    mapping(address => uint256) public _shares;

    /// @notice The token allowances
    mapping(address => mapping(address => uint256)) public _allowances;

    /// @notice The maximum allowed minted Glacial AVAX
    uint256 public _maxSupply;

    /// @notice The total network shares that have a claim by depositors
    uint256 public _totalShares;

    /// @notice The Glacier protocol addresses
    GlacierAddressBook public addresses;

    /// @notice The amount of AVAX that has been sent to the staging wallet
    uint256 public totalNetworkAVAX;

    /// @notice The percentage of overall funds that are kept onhand for liquid withdraws
    uint256 public reservePercentage;

    /// @notice When enabled, withdraw limits will be put in place to slow down withdraw pressure
    bool public throttleNetwork;

    /// @notice The current amount to be withdrawn from the network
    uint256 public withdrawRequestTotal;
    
    /// @notice The all time volume of AVAX that has gone through "completed" withdraw requests (i.e. claimed or cancelled)  
    uint256 public totalWithdrawRequestAmount;

    struct WithdrawRequest {
        address user;
        bool claimed;
        bool canceled;
        uint256 amount;
        uint256 pointer; // The pointer is used to index into the `totalWithdrawRequestAmount` variable
        uint256 shares;
    }

    /// @notice A mapping of withdraw requests to their IDs
    mapping(uint256 => WithdrawRequest) public withdrawRequests;

    /// @notice A counter for the withdraw requests
    uint256 public totalWithdrawRequests;

    /// @notice A counter for how many withdraw requests have been fufilled
    uint256 public totalWithdrawRequestsFufilled;

    /// @notice A mapping of withdraw request IDs to the owner IDs
    mapping(uint256 => uint256) public withdrawRequestIndex;

    /// @notice A mapping of withdrawers to another mapping of the owner index to the withdraw request ID
    mapping(address => mapping(uint256 => uint256)) public userWithdrawRequests;

    /// @notice A mapping of withdrawers to the total amount of withdraw requests
    mapping(address => uint256) public userWithdrawRequestCount;

    /// @notice Emitted when a user deposits AVAX into Glacier
    /// @param avaxAmount Is in units of AVAX to mark the historical conversion rate
    event Deposit(address indexed user, uint256 avaxAmount, uint64 referralCode);

    /// @notice Emitted when a user withdraws AVAX from Glacier
    /// @param avaxAmount Is in units of AVAX to mark the historical conversion rate
    event Withdraw(address indexed user, uint256 avaxAmount);

    /// @notice Emitted when a user requests to withdraw an amount of AVAX from Glacier
    /// @param avaxAmount Is in units of AVAX to mark the historical conversion rate
    /// @dev This event is only emitted if all other withdrawal methods have been exhausted
    ///      GlacialBot will monitor this event stream and request withdrawals from the network
    ///      before satisfying the requests itself.
    event UserWithdrawRequest(address indexed user, uint256 avaxAmount);

    /// @notice Emitted automatically by the protocol to release some AVAX from the network
    event ProtocolWithdrawRequest(uint256 avaxAmount);

    /// @notice Emitted when a user cancels their withdraw request, notifying the network to wipe the previous withdraw request
    event CancelWithdrawRequest(address indexed user, uint256 id);

    /// @notice Emitted when a user claims withdrawn AVAX
    /// @param avaxAmount Is in units of AVAX to mark the historical conversion rate
    event Claim(address indexed user, uint256 avaxAmount);

    /// @notice Emitted when a user throttles the network with a large withdrawal
    event NetworkThrottled(address indexed user);

    /// @notice Emitted when AVAX is refilled into this contract
    event RefillAVAX(uint256 amount);

    /**
     * @notice Initialize, called when proxy is deployed
     * @dev The deployment will fail if wavaxAddress isn't set to a valid ERC20 token in the `addresses` contract.
     */
    function initialize(GlacierAddressBook _addresses) public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(NETWORK_MANAGER, msg.sender);

        addresses = _addresses;

        // Approve the spending of WAVAX in this control by the reserve pool and the lending pool
        IERC20Upgradeable(addresses.wavaxAddress()).approve(addresses.reservePoolAddress(), type(uint256).max);
        IERC20Upgradeable(addresses.wavaxAddress()).approve(addresses.lendingPoolAddress(), type(uint256).max);
    }

    /**
     * @notice Deposits AVAX into the Glacier protocol
     */
    receive() external payable {
        // prevents direct sending from a user
        require(msg.sender != tx.origin);
    }

    /**
     * @notice Deposits AVAX into the Glacier protocol
     * @param referralCode The referral code of someone
     */
    function deposit(uint64 referralCode) public payable nonReentrant whenNotPaused returns (uint256) {
        address user = msg.sender;
        require(msg.value > 0, "ZERO_DEPOSIT");
        if (_maxSupply > 0) {
            require(totalAVAX() + msg.value <= _maxSupply, "MAXIMUM_AVAX_REACHED");
        }

        uint256 depositAmount = msg.value;

        if(_totalShares == 0){
           require(msg.value > MINIMUM_LIQUIDITY, "INSUFFICIENT_DEPOSIT");
           // permanently lock the first MINIMUM_LIQUIDITY tokens
           uint256 sharesMinimun = sharesFromAvax(MINIMUM_LIQUIDITY);
           _mintShares(address(1), sharesMinimun);
           depositAmount -= MINIMUM_LIQUIDITY;
        }

        // Mint back to the user the total glAVAX amount of their AVAX deposit
        uint256 sharesAmount = sharesFromAvax(depositAmount);
        _mintShares(user, sharesAmount);

        /// @dev This function is important as it repays back any outstanding loans the protocol took to satisfy withdrawals.
        ///      1. First it checks for user withdrawals.
        ///      2. Then it pays back any atomic buys
        ///      3. Then it pays back any loans
        ///      4. It then leaves the rest which will get picked up as reserves every day
        _repayLiquidity(depositAmount);

        emit Deposit(user, msg.value, referralCode);

        return sharesAmount;
    }

    /**
     * @notice Withdraws AVAX from the Glacier protocol
     * @param amount The amount in glAVAX
     * @dev Withdrawal Sourcing handling:
     *      1. Router AVAX
     *      2. Reserve Pool
     *      3. OTC Lending
     *      4. Atomic Buying
     *      5. Glacier Network
     */
    function withdraw(uint256 amount) external nonReentrant {
        address user = msg.sender;
        require(amount > 0, "ZERO_WITHDRAW");
        require(amount <= balanceOf(user), "INSUFFICIENT_BALANCE");

        // add this amount to total active withdraw request
        withdrawRequestTotal += amount;

        /// @dev We store the variables ahead of execution as this function can end up changing ratios which can affect implicit nature
        uint256 avaxAmount = amount;
        uint256 totalWithdrawAvaxAmount = avaxAmount;

        // First check the AVAX that is held on hand
        // The pool will hold reserve funds + any extra deposits that happened during the day
        uint256 depositAmount = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
        if (avaxAmount > 0 && depositAmount > 0) {
            uint256 onHandAmount = depositAmount > avaxAmount ? avaxAmount : depositAmount;
            avaxAmount -= onHandAmount;
        }

        // Then check the AVAX that is held in the reserve pool
        uint256 reserveBalance = IGReservePool(addresses.reservePoolAddress()).totalReserves();
        if (avaxAmount > 0 && reserveBalance > 0) {
            uint256 reserveAmount = reserveBalance > avaxAmount ? avaxAmount : reserveBalance;
            IGReservePool(addresses.reservePoolAddress()).withdraw(reserveAmount);
            avaxAmount -= reserveAmount;
        }

        avaxAmount = _borrowLiquidity(avaxAmount);

        // Finally, as a last resort, we want to issue a withdraw request to the network
        // If this logic is hit, then we enable daily limits to throttle the network
        if (avaxAmount > 0) {
            throttleNetwork = true;
            _withdrawRequest(avaxAmount);
        }

        /// Withdraw AVAX from WAVAX and burn the related glAVAX tokens
        uint256 toWithdraw = totalWithdrawAvaxAmount - avaxAmount;
        if (toWithdraw > 0) {
            uint256 sharesToBurn = sharesFromAvax(toWithdraw);
            IWAVAX(addresses.wavaxAddress()).withdraw(toWithdraw);
            _burn(user, sharesToBurn);
            // Transfer the user with the AVAX
            payable(user).transfer(toWithdraw);

            _updateWithdrawTotal(toWithdraw);
        }

        emit Withdraw(user, totalWithdrawAvaxAmount);
    }

    /**
     * @notice Allows a user to claim the amount of AVAX that is ready from their withdrawal request
     * @dev This function will claim any currently fufilled requests, and ignore non-fufilled requests
     */
    function claimAll() external payable nonReentrant {
        address user = msg.sender;
        uint256 requests = userWithdrawRequestCount[user];
        require(requests > 0, "NO_ACTIVE_REQUESTS");
        for (uint256 i = 0; i < requests; ++i) {
            uint256 id = requestIdFromUserIndex(user, i);
            WithdrawRequest storage request = withdrawRequests[id];
            // Check for fufilled requests that haven't been claimed
            if (_canClaim(request)) {
                _claim(request);
            }
        }
    }

    /**
     * @notice Allows a user to claim the amount of AVAX that is ready from their withdrawal request
     * @dev This function will revert if the request isn't yet fufilled
     */
    function claim(uint256 id) external payable nonReentrant {
         uint256 idFromUser = requestIdFromUserIndex(msg.sender, id);
         WithdrawRequest storage request = withdrawRequests[idFromUser];
         require(_canClaim(request), "NOT_CLAIMABLE");
         _claim(request);
    }

    /**
     * @notice Cancels all the users withdrawal requests and returns the glAVAX to the user
     */
    function cancelAll() external nonReentrant {
        address user = msg.sender;
        uint256 requests = userWithdrawRequestCount[user];
        require(requests > 0, "NO_ACTIVE_REQUESTS");
        for (uint256 i = requests; i > 0; --i) {
            uint256 id = requestIdFromUserIndex(user, i - 1);
            _cancel(id);
        }
    }

    /**
     * @notice Cancels a single user withdrawal request and returns the glAVAX to the user
     */
    function cancel(uint256 index) external nonReentrant {
        uint256 id = requestIdFromUserIndex(msg.sender, index);
        _cancel(id);
    }

    /**
     * @notice Rebalances the contracts, distributing any necessary AVAX across the reserve pool and the network
     * @dev Called every 24-hours by the rebalancer
     */
    function rebalance() external payable isRole(NETWORK_MANAGER) {
        uint256 balance = deposits();
        address reservePoolAddress = addresses.reservePoolAddress();
        uint256 currentReserves = IGReservePool(reservePoolAddress).totalReserves();
        uint256 reserveTarget = totalAVAX() * reservePercentage / PERCENTAGE_PRECISION;

        // If we have any deposits in the contract, then we have spillover.
        // Send this to the reserves and to the network.
        if (balance > 0 && currentReserves < reserveTarget) {
            uint256 toFill = reserveTarget - currentReserves;
            uint256 toReserves = toFill > balance ? balance : toFill;
            IGReservePool(reservePoolAddress).deposit(toReserves);
            balance -= toReserves;
        } else {
            // Otherwise withdraw the excess so we can move it into the network
            IGReservePool(reservePoolAddress).withdraw(currentReserves - reserveTarget);
            balance += currentReserves - reserveTarget;
        }

        if (balance > 0) {
            totalNetworkAVAX += balance;
            IWAVAX(addresses.wavaxAddress()).withdraw(balance);
            payable(addresses.networkWalletAddress()).transfer(balance);
        }

        // Then if we are still indebted to the protocol, issue a refill request to the network
        uint256 withdrawAmount = 0;
        currentReserves = IGReservePool(reservePoolAddress).totalReserves();
        if (currentReserves < reserveTarget) {
            withdrawAmount += reserveTarget - currentReserves;
        }

        uint256 totalLoaned = IGLendingPool(addresses.lendingPoolAddress()).totalLoaned();
        if (totalLoaned > 0) {
            withdrawAmount += totalLoaned;
        }

        if (withdrawAmount > 0) {
            emit ProtocolWithdrawRequest(withdrawAmount);
        }
    }

    /**
     * @notice Deposits AVAX directly from a protocol management wallet
     * @dev This is responsible for delegating AVAX to user withdrawals, and other parts of the protocol that are owed AVAX
     */
    function fufillWithdrawal() external payable isRole(NETWORK_MANAGER) {
        uint256 avaxAmount = msg.value;

        // Transfer the balance from the network to the contract
        totalNetworkAVAX -= avaxAmount;

        /// @dev This function is important as it repays back any outstanding loans the protocol took to satisfy withdrawals.
        ///      1. First it checks for user withdrawals.
        ///      2. Then it pays back any atomic buys
        ///      3. Then it pays back any loans
        ///      4. It then leaves the rest which will get picked up as reserves every day
        _repayLiquidity(avaxAmount);
    }

    /**
     * @notice Sets the maximum amount of AVAX we're taking on.
     * @dev Set to 0 to disable
     */
    function setMaxSupply(uint256 amount) external isRole(NETWORK_MANAGER) {
        _maxSupply = amount;
    }

    /**
     * @notice Stops accepting new AVAX deposits into the protocol, while still allowing withdrawals to continue.
     */
    function pauseDeposits() external isRole(NETWORK_MANAGER) {
        _pause();
    }

    /**
     * @notice Resumes accepting new AVAX deposits
     */
    function resumeDeposits() external isRole(NETWORK_MANAGER) {
        _unpause();
    }

    /**
     * @notice Configures the reserve percentage
     */
    function setReservePercentage(uint256 _reservePercentage) external isRole(NETWORK_MANAGER) {
        reservePercentage = _reservePercentage;
    }

    /**
     * @notice Restores the network so that it can continue to run optimally
     */
    function restoreNetwork() external isRole(NETWORK_MANAGER) {
        throttleNetwork = false;
    }

    /**
     * @notice Sets the new network total
     * @dev To be used manually by the development team
     *
     * Requirements:
     *  - The contract must not be paused
     */
    function setNetworkTotal(uint256 newNetworkTotal) external isRole(NETWORK_MANAGER) whenNotPaused {
        totalNetworkAVAX = newNetworkTotal;
    }

    /**
     * @notice Increases the network total by `amount`
     * @dev To be called by the network manager
     */
    function increaseNetworkTotal(uint256 amount) external isRole(NETWORK_MANAGER) {
        totalNetworkAVAX += amount;
    }

    /**
     * @notice Returns the withdraw request index from a given user by the user withdraw request index
     */
    function requestIdFromUserIndex(address user, uint256 index) public view virtual returns (uint256) {
        require(index < userWithdrawRequestCount[user], "INDEX_OUT_OF_BOUNDS");
        return userWithdrawRequests[user][index];
    }

    /**
     * @notice Returns a withdraw request by its index
     */
    function requestById(uint256 id) public view virtual returns (WithdrawRequest memory) {
        require(id < totalWithdrawRequests, "INDEX_OUT_OF_BOUNDS");
        return withdrawRequests[id];
    }


    /**
     * @notice Calculates whether or not a certain amount of AVAX withdrawal will throttle the network
     */
    function willThrottleNetwork(uint256 withdrawalAmount) public view returns (bool) {
        uint256 liq = liquidity();
        if (withdrawalAmount > liq) {
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice ERC-20 function to return the total amount of AVAX in the system
     */
    function totalSupply() public view virtual override returns (uint256) {
        return netAVAX();
    }

    /**
     * @notice Returns the total amount of AVAX currently in the protocol (i.e. all of the network AVAX, the reserve pool AVAX, and any onhand deposits)
     */
    function totalAVAX() public view returns (uint256) {
        return totalNetworkAVAX + IGReservePool(addresses.reservePoolAddress()).totalReserves()
            + IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of AVAX that should be in the protocol (i.e. factoring in loans)
     */
    function netAVAX() public view returns (uint256) {
        return totalAVAX() - IGLendingPool(addresses.lendingPoolAddress()).totalLoaned();
    }

    /**
     * @notice Returns the amount of spillover deposits that were collected today
     */
    function deposits() public view returns (uint256) {
        return IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of AVAX that is ready to be claimed by the network
     */
    function claimable() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Returns the total amount of liquidity there is to facilitate withdrawals
     */
    function liquidity() public view returns (uint256) {
        // FUTURE FEATURE: Adding USDC purchaser to help offset delta risk
        return deposits() + IGReservePool(addresses.reservePoolAddress()).totalReserves()
            + IGLendingPool(addresses.lendingPoolAddress()).totalReserves();
    }

    /**
     * @notice Returns the users balance
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return avaxFromShares(_shares[account]);
    }

    function sharesOf(address account) public view returns (uint256) {
        return _shares[account];
    }

    /**
     * @notice Returns the amount of shares correspond to the `avaxAmount`
     */
    function sharesFromAvax(uint256 avaxAmount) public view returns (uint256) {
        uint256 totalAvax = netAVAX();
        if (totalAvax == 0 || _totalShares == 0) {
            return avaxAmount;
        }

        return avaxAmount.mulDiv(_totalShares, totalAvax, Math.Rounding.Down);
    }

    /**
     * @notice Returns the amount of AVAX that corresponds to the `shareAmount`
     */
    function avaxFromShares(uint256 shareAmount) public view returns (uint256) {
        uint256 totalAvax = netAVAX();
        if (_totalShares == 0) {
            return shareAmount;
        }

        return shareAmount.mulDiv(totalAvax, _totalShares, Math.Rounding.Down);
    }

    /**
     * @notice lets you know if the user can claim is withdrawal
     */
    function canClaim(uint256 id) public view returns (bool){
        WithdrawRequest memory request = requestById(id);
        return _canClaim(request); 
    }

    /**
     * @notice Mints shares to a user account
     */
    function _mintShares(address account, uint256 shareAmount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalShares += shareAmount;
        _shares[account] += shareAmount;
    }

    /**
     * @notice Burns shares from a user account
     */
    function _burnShares(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");
        uint256 accountBalance = _shares[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _shares[account] = accountBalance - amount;
        }
        _totalShares -= amount;
    }

    /**
     * @notice Grants liquidity to the Glacier Pool to facilitate withdrawals
     * @param amount The amount of AVAX we are trying to raise
     */
    function _borrowLiquidity(uint256 amount) internal returns (uint256) {
        // Check if there is any AVAX that we can lend out from the lending pool
        uint256 borrowAmount = _lendAvax(amount);
        amount -= borrowAmount;

        // TODO: Use other methods of borrowing, i.e. purchasing AVAX atomically

        return amount;
    }

    /**
     * @notice This contract takes out a loan of `amount` AVAX from the lending pool
     */
    function _lendAvax(uint256 amount) internal returns (uint256) {
        uint256 lendingBalance = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(addresses.lendingPoolAddress());
        if (amount > 0 && lendingBalance > 0) {
            uint256 borrowAmount = lendingBalance > amount ? amount : lendingBalance;
            IGLendingPool(addresses.lendingPoolAddress()).borrow(borrowAmount);
            return borrowAmount;
        } else {
            return 0;
        }
    }

    /**
     * @notice Repays liquidity that was borrowed by the Glacier Pool
     */
    function _repayLiquidity(uint256 avaxAmount) internal {
        require(avaxAmount > 0, "ZERO_DEPOSIT");
       
       // first dedicate avax to withdraw request
       _rebalanceWithdraw();

        uint256 wavaxBalance = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));

        address lendingPool = addresses.lendingPoolAddress();

        // If any AVAX is owed to the lending pool, prioritize paying this back first before the reserves
        uint256 totalLoaned = IGLendingPool(lendingPool).totalLoaned();
        if (wavaxBalance > 0 && totalLoaned > 0) {
            // FUTURE FEATURE: Adding USDC purchaser to help offset delta risk
            // uint256 totalBought = IGLendingPool(addresses.lendingPoolAddress()).totalBought();
            // if (totalBought > 0) {
            //     uint256 repayAmount = totalBought > amount ? amount : totalBought;
            //     IGLendingPool(addresses.lendingPoolAddress()).repayBought(address(this), repayAmount);
            //     amount -= repayAmount;
            // }

            // we reimbourse from actual wavax balance
            uint256 repayAmount = totalLoaned > wavaxBalance ? wavaxBalance : totalLoaned;
            IGLendingPool(lendingPool).repay(repayAmount);
        }
    }

    /**
     * @notice Notifies the network that a withdrawal needs to be made.
     */
    function _withdrawRequest(uint256 amount) internal {
        address user = msg.sender;
        require(amount <= balanceOf(user), "INSUFFICIENT_BALANCE");

        WithdrawRequest memory request =
            WithdrawRequest({user: user, amount: amount, canceled: false, claimed: false, pointer: totalAmountWithdrawn, shares: sharesFromAvax(amount)});

        // Setup the withdraw request data
        withdrawRequests[totalWithdrawRequests] = request;
        userWithdrawRequests[user][userWithdrawRequestCount[user]] = totalWithdrawRequests;
        withdrawRequestIndex[totalWithdrawRequests] = userWithdrawRequestCount[user];
        ++userWithdrawRequestCount[user];
        ++totalWithdrawRequests;

        // Transfer the glAVAX into the contract to hold it for the interim period
        _transfer(user, address(this), amount);

        emit UserWithdrawRequest(user, amount);
    }

    /**
     * @notice Adjust avax and wavax balance of the contract to sastify withdraw requests
     */
    function _rebalanceWithdraw() private {
        uint256 avaxBalance = address(this).balance;
        // first check if we have enough avax token in the contract to sastify withdraw
        if(avaxBalance > withdrawRequestTotal){
            // we deposit unnecessary token
            uint256 tokenToDeposit = avaxBalance - withdrawRequestTotal;
            IWAVAX(addresses.wavaxAddress()).deposit{value: tokenToDeposit}();
        }
        else if (avaxBalance < withdrawRequestTotal){
            // if we don't have enough  avax, try to withdraw wavax to sastify it
            uint256 tokenNeeded = withdrawRequestTotal - avaxBalance;
            uint256 wavaxBalance = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
            if(wavaxBalance > 0){
                uint256 amountToWithdraw = wavaxBalance > tokenNeeded ?  wavaxBalance : tokenNeeded;
                IWAVAX(addresses.wavaxAddress()).withdraw(amountToWithdraw);
            }
        }
    }

    /**
     * @notice Internal logic for claiming
     */
    function _claim(WithdrawRequest storage request) internal {
        address user = msg.sender;
        require(request.user == user, "USER_NOT_CLAIMER");
        request.claimed = true;
        uint256 amountFromShare = avaxFromShares(request.shares);
        // we give the smaller amount between share and requested amount to prevent from frontrunning/slashing
        uint256 requestedAmount = amountFromShare > request.amount ? request.amount : amountFromShare;
        // burn share own by the contract before transfer        
        _burnShares(address(this), request.shares);
        // update total widrawal info (we track from request amount to facilitate calculation)
        _updateWithdrawTotal(request.amount);
        // transfer amount to user
        payable(user).transfer(requestedAmount);
        emit Claim(user, requestedAmount);
    }

    /**
     * @notice Internal logic for cancelling requests
     */
    function _cancel(uint256 id) internal {
        address user = msg.sender;
        WithdrawRequest storage request = withdrawRequests[id];
        require(!request.claimed, "ALREADY_CLAIMED");
        require(!request.canceled, "ALREADY_CANCELED");
        require(request.user == user, "USER_NOT_WITHDRAWER");

        uint256 amountFromShare = avaxFromShares(request.shares);
        // we track from request amount to facilitate calculation
        _updateWithdrawTotal(request.amount);
        request.canceled = true;
        request.claimed = false;
        _removeRequest(user, id);
        // we transfer the shares requested to prevent a part being stuck into the contract
        _transfer(address(this), user, amountFromShare);
        emit CancelWithdrawRequest(user, id);
    }

    /**
     * @notice Removes a request ID from a user
     * @dev `index` referres to the index from the enumerable owner requests which gets the request ID
     *      `id` refers to the actual request ID to get the request data
     */
    function _removeRequest(address user, uint256 id) internal {
        uint256 backIndex = userWithdrawRequestCount[user] - 1;
        uint256 toDeleteIndex = withdrawRequestIndex[id];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (toDeleteIndex != backIndex) {
            uint256 backId = userWithdrawRequests[user][backIndex];

            // Move the request thats at the back of the queue to the index of the token we are deleting
            // This lets us reduce the total withdraw requests and still be able to iterate over the total amount
            userWithdrawRequests[user][toDeleteIndex] = backId;

            // Now move the request we are deleting to the back of the list
            withdrawRequestIndex[backId] = toDeleteIndex;
        }

        // This also deletes the contents at the last position of the array
        delete withdrawRequestIndex[id];
        delete userWithdrawRequests[user][backIndex];
        userWithdrawRequestCount[user]--;
    }

    /**
     * @notice Determines whether a given request is eligible for claiming
     */
    function _canClaim(WithdrawRequest memory request) private view returns (bool){
        return !request.claimed && !request.canceled && totalWithdrawRequestAmount >= request.pointer + request.amount; 
    }

    /**
     * @notice Update total withdraw request amount after a claim or a cancel
     */
    function _updateWithdrawTotal(uint256 amount) private {
        withdrawRequestTotal -= amount;
        totalWithdrawRequestAmount += amount; 
    }         

    /**
     * ==============================================================
     *             ERC-20 Functions
     * ==============================================================
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        uint256 shareAmount = sharesFromAvax(amount);

        _beforeTokenTransfer(from, to, shareAmount);

        uint256 fromBalance = _shares[from];
        require(fromBalance >= shareAmount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _shares[from] = fromBalance - shareAmount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            _shares[to] += shareAmount;
        }

        emit Transfer(from, to, shareAmount);

        _afterTokenTransfer(from, to, shareAmount);
    }

    function name() external view virtual returns (string memory) {
        return NAME;
    }

    function symbol() external view virtual returns (string memory) {
        return SYMBOL;
    }

    function decimals() external view virtual returns (uint8) {
        return DECIMALS;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, _allowances[owner][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = _allowances[owner][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalShares += amount;
        _shares[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _shares[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _shares[account] = accountBalance - amount;
        }
        _totalShares -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}