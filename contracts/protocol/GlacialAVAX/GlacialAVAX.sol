// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import { IWAVAX } from "../../interfaces/IWAVAX.sol";
import { IGReservePool } from "../../interfaces/IGReservePool.sol";
import { IGLendingPool } from "../../interfaces/IGLendingPool.sol";
import { AccessControlManager } from "../../AccessControlManager.sol";
import { GlacierAddressBook } from "../../GlacierAddressBook.sol";

import "hardhat/console.sol";

/**
 * @title  Glacial AVAX ERC-20 token implementation
 * @author Jack Frost
 * @notice GlacialAvax (glAVAX) is a DeFi-friendly AVAX derivative that represents AVAX deposited into the Glacier protocol. It can be redeemed back for AVAX at an exchange rate that builds value over time based on the 
 *         performance and accrued rewards from the Glacier network.
 *
 *         Handles all of the depositing and withdrawing, the exchange rate between AVAX <-> glAVAX, the rebalancing logic and the withdraw requests.
 */
contract glAVAX is Initializable, IERC20Upgradeable, AccessControlManager, ReentrancyGuardUpgradeable {

    /// @notice Token Info
    string private constant NAME     = "Glacial AVAX";
    string private constant SYMBOL   = "glAVAX";
    uint8  private constant DECIMALS = 18;

    /// @notice Token balances
    mapping(address => uint256) public _balances;
    
    /// @notice The token allowances
    mapping(address => mapping(address => uint256)) public _allowances;
    
    /// @notice The total supply that is currently in circulation
    uint256 public _totalGlavax;

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

    /// @notice The amount of claimable AVAX inside this contract
    uint256 public claimableAmount;
    
    struct WithdrawRequest {
        uint256 glavaxAmount;
        uint256 avaxAmount;
        uint256 timestamp;
        bool fufilled;
        bool claimed;
    }

    /// @notice A mapping of withdraw requests to their IDs
    mapping(uint256 => WithdrawRequest) public _withdrawRequests;

    /// @notice A counter for the withdraw requests
    uint256 public _totalWithdrawRequests;

    /// @notice A counter for how many withdraw requests have been fufilled
    uint256 public _totalWithdrawRequestsFufilled;

    /// @notice A mapping of withdraw request IDs to the owner IDs
    mapping(uint256 => uint256) public _withdrawRequestIndex;

    /// @notice A mapping of withdrawers to another mapping of the owner index to the withdraw request ID
    mapping(address => mapping(uint256 => uint256)) public _userWithdrawRequests;

    /// @notice A mapping of withdrawers to the total amount of withdraw requests
    mapping(address => uint256) public _userWithdrawRequestCount;

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

    function initialize(GlacierAddressBook _addresses) initializer public {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(NETWORK_MANAGER, msg.sender);

        addresses = _addresses;

        // Approve the spending of WAVAX in this control by the reserve pool and the lending pool
        IERC20Upgradeable(addresses.wavaxAddress()).approve(addresses.reservePoolAddress(), type(uint256).max);
        IERC20Upgradeable(addresses.wavaxAddress()).approve(addresses.lendingPoolAddress(), type(uint256).max);
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
     */
    function setNetworkTotal(uint256 newNetworkTotal) external isRole(NETWORK_MANAGER) {
        totalNetworkAVAX = newNetworkTotal;
    }

    /**
     * @notice Rebalances the contracts, distributing any necessary AVAX across the reserve pool and the network
     * @dev Called every 24-hours by the rebalancer
     */
    function rebalance() external payable isRole(NETWORK_MANAGER) {
        uint256 balance = deposits();
        uint256 currentReserves = IGReservePool(addresses.reservePoolAddress()).totalReserves();
        uint256 reserveTarget = totalAVAX() * reservePercentage / 1e4;

        // If we have any deposits in the contract, then we have spillover.
        // Send this to the reserves and to the network.
        if (balance > 0) {
            if (currentReserves < reserveTarget) {
                uint256 toFill = reserveTarget - currentReserves;
                uint256 toReserves = toFill > balance ? balance : toFill;
                IGReservePool(addresses.reservePoolAddress()).deposit(toReserves);
                balance -= toReserves;
            } else {
                // Otherwise withdraw the excess so we can move it into the network
                IGReservePool(addresses.reservePoolAddress()).withdraw(currentReserves - reserveTarget);
                balance += currentReserves - reserveTarget;
            }

            if (balance > 0) {
                totalNetworkAVAX += balance;
                IWAVAX(addresses.wavaxAddress()).withdraw(balance);
                payable(addresses.networkWalletAddress()).transfer(balance);
            }
        }

        // Then if we are still indebted to the protocol, issue a refill request to the network
        uint256 withdrawAmount = 0;
        currentReserves = IGReservePool(addresses.reservePoolAddress()).totalReserves();
        if (currentReserves < reserveTarget) {
            withdrawAmount += reserveTarget - currentReserves;
        }

        uint256 totalOwed = IGLendingPool(addresses.lendingPoolAddress()).totalOwed();
        if (totalOwed > 0) {
            withdrawAmount += totalOwed;
        }

        if (withdrawAmount > 0) {
            emit ProtocolWithdrawRequest(withdrawAmount);
        }
    }

    /**
     * @notice Deposits AVAX into the Glacier protocol
     */
    receive() external payable {}

    /**
     * @notice Helper function to return a users current AVAX they'd receive for a specific amount of glAVAX
     */
    function avaxBalance(address user) external view returns (uint256) {
        return avaxFromGlavax(balanceOf(user));
    }

    /**
     * @notice Calculates how much AVAX you'd receive for glAVAX
     */
    function avaxFromGlavax(uint256 glavaxAmount) public view returns (uint256) {
        uint256 totalAvax = netAVAX();
        if (_totalGlavax == 0) {
            return glavaxAmount;
        }
        return glavaxAmount * totalAvax / _totalGlavax;
    }

    /**
     * @notice Calculates how much glAVAX you'd receive for AVAX
     */
    function glavaxFromAvax(uint256 avaxAmount) public view returns (uint256) {
        uint256 totalAvax = netAVAX();
        if (totalAvax == 0 || _totalGlavax == 0) {
            return avaxAmount;
        }
        return avaxAmount * _totalGlavax / totalAvax;
    }

    /**
     * @notice Returns the total amount of AVAX currently in the protocol (i.e. all of the network AVAX, the reserve pool AVAX, and any onhand deposits)
     */
    function totalAVAX() public view returns (uint256) {
        return totalNetworkAVAX + IGReservePool(addresses.reservePoolAddress()).totalReserves() + IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of AVAX that should be in the protocol (i.e. factoring in loans)
     */
    function netAVAX() public view returns (uint256) {
        return totalAVAX() - IGLendingPool(addresses.lendingPoolAddress()).totalOwed();
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
     * @notice Returns the total amount of liquidity there is to facilitate a withdrawal
     */
    function liquidity() public returns (uint256) {
        return deposits() + IGReservePool(addresses.reservePoolAddress()).totalReserves() + IGLendingPool(addresses.lendingPoolAddress()).totalReserves() + IGLendingPool(addresses.lendingPoolAddress()).purchasingPower();
    }

    /**
     * @notice Calculates whether or not a certain amount of AVAX will throttle the network
     */
    function willThrottleNetwork(uint256 withdrawalAmount) public returns (bool) {
        uint256 liq = liquidity();
        if (withdrawalAmount > liq) {
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice Deposits AVAX into the Glacier protocol
     * @param user The user that is initiating this deposit
     * @param referralCode The referral code of someone
     */
    function deposit(address user, uint64 referralCode) public payable nonReentrant {
        require(msg.sender == user, "USER_NOT_SENDER");
        require(msg.value > 0, "ZERO_DEPOSIT");

        uint256 avaxAmount = msg.value;

        /// @dev This function is important as it repays back any outstanding loans the protocol took to satisfy withdrawals.
        ///      1. First it checks for user withdrawals.
        ///      2. Then it pays back any atomic buys
        ///      3. Then it pays back any loans
        ///      4. It then leaves the rest which will get picked up as reserves every day
        avaxAmount = _repayLiquidity(avaxAmount);

        // Mint back to the user the total glAVAX amount of their AVAX deposit
        uint256 glavaxAmount = glavaxFromAvax(msg.value);
        _mint(user, glavaxAmount);

        // Otherwise leave the AVAX in the contract
        IWAVAX(addresses.wavaxAddress()).deposit{value: avaxAmount}();

        emit Deposit(user, msg.value, referralCode);
    }

    /**
     * @notice Withdraws AVAX from the Glacier protocol
     * @param user The user that is initiating this withdrawal
     * @param glavaxAmount The amount in glAVAX
     * @dev Withdrawal Sourcing handling:
     *      1. Router AVAX
     *      2. Reserve Pool
     *      3. OTC Lending
     *      4. Atomic Buying
     *      5. Glacier Network
     */
    function withdraw(address user, uint256 glavaxAmount) external nonReentrant {
        require(msg.sender == user, "USER_NOT_SENDER");
        require(glavaxAmount > 0, "ZERO_WITHDRAW");
        require(glavaxAmount <= _balances[user], "INSUFFICIENT_BALANCE");

        /// @dev We store the variables ahead of execution as this function can end up changing ratios which can affect implicit nature
        uint256 avaxAmount = avaxFromGlavax(glavaxAmount);
        uint256 totalWithdrawAvaxAmount = avaxAmount;

        // First check the AVAX that is held on hand
        // The pool will hold reserve funds + any extra deposits that happened during the day
        uint256 depositAmount = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this)) - claimableAmount;
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
            _withdrawRequest(user, avaxAmount);
        }

        /// Withdraw AVAX from WAVAX and burn the related glAVAX tokens
        uint256 toWithdraw = totalWithdrawAvaxAmount - avaxAmount;
        if (toWithdraw > 0) {
            uint256 toBurn = glavaxFromAvax(toWithdraw);
            IWAVAX(addresses.wavaxAddress()).withdraw(toWithdraw);
            _burn(user, toBurn);
            // Transfer the user with the AVAX
            payable(user).transfer(toWithdraw);
        }

        emit Withdraw(user, totalWithdrawAvaxAmount);
    }

    /**
     * @notice Grants liquidity to the Glacier Pool to facilitate withdrawals
     * @param amount The amount of AVAX we are trying to raise
     */
    function _borrowLiquidity(uint256 amount) internal returns (uint256) {
        // Check if there is any AVAX that we can lend out from the lending pool
        uint256 borrowAmount = _lendAvax(amount);
        amount -= borrowAmount;

        // Check if there is any USDC that we can use to purchase AVAX
        uint256 boughtAmount = _buyAvax(amount);
        amount -= boughtAmount;

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
     * @notice Uses the lending pool to purchase up to `amount` in AVAX
     */
    function _buyAvax(uint256 amount) internal returns (uint256) {
        uint256 purchasingPower = IGLendingPool(addresses.lendingPoolAddress()).purchasingPower();
        if (amount > 0 && purchasingPower > 0) {
            uint256 buyAmount = amount > purchasingPower ? purchasingPower : amount;
            uint256 balanceBefore = IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this));
            IGLendingPool(addresses.lendingPoolAddress()).buyAndBorrow(buyAmount);
            return IERC20Upgradeable(addresses.wavaxAddress()).balanceOf(address(this)) - balanceBefore;
        } else {
            return 0;
        }
    }

    /**
     * @notice Repays liquidity that was borrowed by the Glacier Pool
     */
    function _repayLiquidity(uint256 avaxAmount) internal returns (uint256) {
        require(avaxAmount > 0, "ZERO_DEPOSIT");
        uint256 amount = msg.value;
        uint256 totalWithdrawRequestAmount = totalWithdrawRequests();
        if (totalWithdrawRequestAmount > 0) {
            uint256 repayAmount = totalWithdrawRequestAmount > amount ? amount : totalWithdrawRequestAmount;
            _fufillUserWithdrawals(repayAmount);
            amount -= repayAmount;
        }

        // If any AVAX is owed to the lending pool, prioritize paying this back first before the reserves
        if (amount > 0 && IGLendingPool(addresses.lendingPoolAddress()).totalOwed() > 0) {
            uint256 totalBought = IGLendingPool(addresses.lendingPoolAddress()).totalBought();
            uint256 totalLoaned = IGLendingPool(addresses.lendingPoolAddress()).totalLoaned();
            if (totalBought > 0) {
                uint256 repayAmount = totalBought > amount ? amount : totalBought;
                IGLendingPool(addresses.lendingPoolAddress()).repayBought(address(this), repayAmount);
                amount -= repayAmount;
            }
            
            if (amount > 0 && totalLoaned > 0) {
                uint256 repayAmount = totalLoaned > amount ? amount : totalLoaned;
                IGLendingPool(addresses.lendingPoolAddress()).repay(address(this), repayAmount);
                amount -= repayAmount;
            }
        }

        return avaxAmount;
    }

    /**
     * @notice Notifies the network that a withdrawal needs to be made.
     */
    function _withdrawRequest(address user, uint256 glavaxAmount) internal {
        require(msg.sender == user, "USER_NOT_SENDER");
        require(glavaxAmount <= _balances[user], "INSUFFICIENT_BALANCE");

        uint256 avaxAmount = avaxFromGlavax(glavaxAmount);

        WithdrawRequest memory request = WithdrawRequest({
            glavaxAmount: glavaxAmount,
            avaxAmount: 0,
            timestamp: block.timestamp,
            fufilled: false,
            claimed: false
        });

        // Setup the withdraw request data
        _withdrawRequests[_totalWithdrawRequests] = request;
        _userWithdrawRequests[user][_userWithdrawRequestCount[user]] = _totalWithdrawRequests;
        _withdrawRequestIndex[_totalWithdrawRequests] = _userWithdrawRequestCount[user];
        ++_userWithdrawRequestCount[user];
        ++_totalWithdrawRequests;

        // Transfer the glAVAX into the contract to hold it for the interim period
        transferFrom(user, address(this), glavaxAmount);

        emit UserWithdrawRequest(user, avaxAmount);
    }

    /**
     * @notice Returns the withdraw request index from a given user by the user withdraw request index
     */
    function requestIdFromUserIndex(address user, uint256 index) public view virtual returns (uint256) {
        require(index < _userWithdrawRequestCount[user], "INDEX_OUT_OF_BOUNDS");
        return _userWithdrawRequests[user][index];
    }   

    /**
     * @notice Returns a withdraw request by its index
     */
    function requestById(uint256 id) public view virtual returns (WithdrawRequest memory) {
        require(id < totalWithdrawRequests(), "INDEX_OUT_OF_BOUNDS");
        return _withdrawRequests[id];
    }

    /**
     * @notice Allows a user to claim the amount of AVAX that is ready from their withdrawal request
     * @dev This function will claim any currently fufilled requests, and ignore non-fufilled requests
     */
    function claimAll(address user) external payable nonReentrant {
        require(msg.sender == user, "USER_NOT_SENDER");
        uint256 requests = _userWithdrawRequestCount[user];
        require(requests > 0, "NO_ACTIVE_REQUESTS");
        for (uint256 i = 0; i < requests; ++i) {
            uint256 id = requestIdFromUserIndex(user, i);
            WithdrawRequest memory request = _withdrawRequests[id];
            if (request.fufilled) {
                _claim(user, i);
            }
        }
    }

    /**
     * @notice Allows a user to claim the amount of AVAX that is ready from their withdrawal request
     * @dev This function will revert if the request isn't yet fufilled
     */
    function claim(address user, uint256 id) external payable nonReentrant {
        WithdrawRequest memory request = _withdrawRequests[id];
        require(request.fufilled, "REQUEST_NOT_FUFILLED");
        require(!request.claimed, "REQUEST_ALREADY_CLAIMED");
        _claim(user, id);
    }

    /**
     * @notice Internal logic for claiming 
     */
    function _claim(address user, uint256 index) internal {
        require(msg.sender == user, "USER_NOT_SENMDER");
        uint256 id = requestIdFromUserIndex(user, index);
        WithdrawRequest storage request = _withdrawRequests[id];
        request.claimed = true;
        uint256 avaxAmount = avaxFromGlavax(request.glavaxAmount);
        IWAVAX(addresses.wavaxAddress()).withdraw(avaxAmount);
        payable(user).transfer(avaxAmount);
        emit Claim(user, avaxAmount);
    }

    /**
     * @notice Cancels all the users withdrawal requests and returns the glAVAX to the user
     */
    function cancelAll(address user) external nonReentrant {
        require(msg.sender == user, "USER_NOT_SENDER");
        uint256 requests = _userWithdrawRequestCount[user];
        require(requests > 0, "NO_ACTIVE_REQUESTS");
        for (uint256 i = requests - 1; i != 0; --i) {
            uint256 id = requestIdFromUserIndex(user, i);
            _cancel(user, id);
        }
        
        if (requests > 0) {
            uint256 id = _userWithdrawRequests[user][0];
            _cancel(user, id);
        }
    }

    /**
     * @notice Cancels a single user withdrawal request and returns the glAVAX to the user
     */
    function cancel(address user, uint256 index) external nonReentrant {
        require(msg.sender == user, "USER_NOT_SENDER");
        uint256 id = _userWithdrawRequests[user][index];
        _cancel(user, id);
    }
    
    /**
     * @notice Internal logic for cancelling requests
     */
    function _cancel(address user, uint256 id) internal {
        require(msg.sender == user, "USER_NOT_SENDER");
        WithdrawRequest memory request = _withdrawRequests[id];
        require(request.glavaxAmount > 0 || request.timestamp > 0, "INVALID_REQUEST");
        _removeRequest(user, id);
        _transfer(address(this), user, request.glavaxAmount);
        emit CancelWithdrawRequest(user, id);
    }

    /**
     * @notice Removes a request ID from a user
     * @dev `index` referres to the index from the enumerable owner requests which gets the request ID
     *      `id` refers to the actual request ID to get the request data 
     */
    function _removeRequest(address user, uint256 id) internal {
        uint256 backIndex = _userWithdrawRequestCount[user] - 1;
        uint256 toDeleteIndex = _withdrawRequestIndex[id];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (toDeleteIndex != backIndex) {
            uint256 backId = _userWithdrawRequests[user][backIndex];
            
            // Move the request thats at the back of the queue to the index of the token we are deleting
            // This lets us reduce the total withdraw requests and still be able to iterate over the total amount
            _userWithdrawRequests[user][toDeleteIndex] = backId;

            // Now move the request we are deleting to the back of the list
            _withdrawRequestIndex[backId] = toDeleteIndex;
        }

        // This also deletes the contents at the last position of the array
        delete _withdrawRequestIndex[id];
        delete _userWithdrawRequests[user][backIndex];
        _userWithdrawRequestCount[user]--;
    }

    /**
     * @notice Deposits AVAX directly from a protocol management wallet
     * @dev This is responsible for delegating AVAX to user withdrawals, and other parts of the protocol that are owed AVAX
     */
    function fufillWithdrawal() external payable isRole(NETWORK_MANAGER) {
        uint256 avaxAmount = msg.value;

        // Transfer the balance from the network to the contract
        IWAVAX(addresses.wavaxAddress()).deposit{value: avaxAmount}();
        totalNetworkAVAX -= avaxAmount;

        /// @dev This function is important as it repays back any outstanding loans the protocol took to satisfy withdrawals.
        ///      1. First it checks for user withdrawals.
        ///      2. Then it pays back any atomic buys
        ///      3. Then it pays back any loans
        ///      4. It then leaves the rest which will get picked up as reserves every day
        avaxAmount = _repayLiquidity(avaxAmount);
    }

    /**
     * @notice Fufills a user withdrawal
     */
    function _fufillUserWithdrawals(uint256 amount) internal {
        IWAVAX(addresses.wavaxAddress()).withdraw(amount);
        uint256 totalAvax = address(this).balance;
        uint256 totalGlavax = glavaxFromAvax(totalAvax);
        for (uint256 i = _totalWithdrawRequestsFufilled; i < _totalWithdrawRequests; ++i) {
            WithdrawRequest storage request =  _withdrawRequests[i];
            if (totalGlavax >= request.glavaxAmount) {
                request.fufilled = true;
                request.avaxAmount = avaxFromGlavax(request.glavaxAmount);

                // Hold the users withdrawal in native AVAX and burn the contract held glAVAX
                _burn(address(this), request.glavaxAmount);

                totalAvax -= request.avaxAmount;
                totalGlavax -= request.glavaxAmount;
                ++_totalWithdrawRequestsFufilled;
            } else {
                break;
            }
        }
    }

    /**
     * @notice Returns the total amount of glAVAX that has been requested for withdrawal
     */
    function totalWithdrawRequests() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = _totalWithdrawRequestsFufilled; i < _totalWithdrawRequests; ++i) {
            total += avaxFromGlavax(_withdrawRequests[i].glavaxAmount);
        }
        return total;
    }

     /**
     * ==============================================================
     *             ERC-20 Functions
     * ==============================================================
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
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

    function totalSupply() public view virtual override returns (uint256) {
        return _totalGlavax;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
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

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
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

        _totalGlavax += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalGlavax -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}