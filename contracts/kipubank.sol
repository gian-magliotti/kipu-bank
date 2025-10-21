// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "hardhat/console.sol";


/**
 * @title KipuBank
 * @notice A decentralized smart contract bank that allows users to deposit and withdraw ETH and ERC-20 tokens.
 *         - Tracks balances per user and per token.
 *         - Converts token deposits and withdrawals to USD value using Chainlink price feeds.
 *         - Enforces a global bank capacity and per-transaction USD withdrawal limits.
 *         - Supports role-based access control with Admin, Manager, and Pauser roles.
 *         - Includes pausability, reentrancy protection, and detailed error handling.
 */

contract KipuBank is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ================= CONSTANTS ================= //
    /** @notice Role with full admin privileges. */
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");   

    /** @notice Manager role with some privileges. */
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");  

    /** @notice Can pause/unpause the contract. */
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");    

    /** @notice Maximum allowed age (in seconds) of a Chainlink price feed update before it's considered stale */
    uint256 public constant ORACLE_HEARTEBAT = 1 hours;      

    // ================= TOKEN STRUCT ================= //
    struct TokenInfo {
        AggregatorV3Interface priceFeed; // Chainlink feed for the token (address(0) allowed for ETH)
        uint8 decimals;                  // token decimals 
        uint256 totalBalance;            // total balance stored in contract for this token (in token units)
    }

    // ================= STATE VARIABLES ================= //
    /** @notice Mapping token address => TokenInfo */
    mapping(address token => TokenInfo) public tokens;

    /** @notice User balances per token. */
    mapping(address user => mapping(address token => uint256 amount)) private _userBalances; 

    /** @notice Total bank capacity in USD. */
    uint256 public bankCapUSD;       

    /** @notice Current bank total in USD. */
    uint256 public currentTotalUSD; 

    /** @notice Max withdrawal in USD. */
    uint256 public withdrawalLimitUSD;

    /** @notice Number of deposits. */
    uint256 public depositCount;       

    /** @notice Number of withdrawals. */
    uint256 public withdrawalCount;      

    // ================= EVENTS ================= //
    /** @notice Emitted when a deposit is made */
    event KipuBank_DepositMade(address indexed user, address indexed token, uint256 amount, uint256 newBalance, uint256 amountUSD);

    /** @notice Emitted when a withdrawal is made */
   event KipuBank_WithdrawalMade(address indexed user, address indexed token, uint256 amount, uint256 newBalance, uint256 amountUSD);

    /** @notice Emitted when a new token is supported */
    event KipuBank_TokenAdded(address indexed token, uint8 tokenDecimals);

    /** @notice Emitted when a token is removed from the bank. */
    event KipuBank_TokenRemoved(address indexed token);

    /** @notice Emitted when bank cap USD is updated */
    event KipuBank_BankCapUpdated(uint256 newBankCapUSD);

    /** @notice Emitted when withdrawal USD is updated */
    event KipuBank_WithdrawalUpdated(uint256 newWithdrawalUSD);

    /** @notice Emitted when contract is paused */
    event KipuBank_Paused(address indexed account, uint256 timestamp);

    /** @notice Emitted when contract is unpaused */
    event KipuBank_Unpaused(address indexed account, uint256 timestamp);

    /** @notice Emitted when a token's price feed is updated */
    event KipuBank_PriceFeedUpdated(address indexed token, address newPriceFeed, uint256 timestamp);

    // ================= ERRORS ================= //
    /** @notice Emitted when bank capacity is exceeded */
    error KipuBank_BankCapacityExceeded(uint256 requestedAmountUSD, uint256 availableCapacityUSD);

    /** @notice Emitted when withdrawal exceeds limit */
    error KipuBank_WithdrawalLimitExceeded(address token, uint256 requestedAmountToken, uint256 requestedAmountUSD, uint256 withdrawalLimitUSD);

    /** @notice Emitted when user balance is insufficient */
    error KipuBank_InsufficientBalance(address token, uint256 requestedAmount, uint256 availableBalance);

    /** @notice Emitted when token transfer fails */
    error KipuBank_TransferFailed(address token, address user, uint256 amount);

    /** @notice Emitted when a zero amount is provided */
    error KipuBank_ZeroAmountError(string context);

    /** @notice Emitted when token is unsupported */
    error KipuBank_UnsupportedToken(string , address token);

    /** @notice Emitted when contract is paused */
    error KipuBank_ContractPaused();

    /** @notice Emitted when user is unauthorized */
    error KipuBank_Unauthorized();

    /** @notice Emitted when the provided address is not a valid ERC-20 token contract. */
    error KipuBank_InvalidToken(string );

    /** @notice Emitted when a provided address is invalid */
    error KipuBank_InvalidAddress(address addr);

    /** @notice Emitted when a provided address is not a contract */
    error KipuBank_InvalidContract(address addr);

    /** @notice Emitted when a price feed is invalid or stale */
    error KipuBank_PriceFeedError(string msg, address pricefeed);

    /** @notice Emitted when a token has invalid decimals */
    error KipuBank_InvalidTokenDecimals(uint8 decimals);

    /** @notice Emitted when attempting to remove a token that still has a non-zero balance */
    error KipuBank_NonZeroBalance(address token, uint256 balance);

    // ================= MODIFIERS ================= //
    /** @notice Ensures that the amount is non-zero */
    modifier checkNonZero(uint256 amount, string memory context) {
        if(amount == 0) {
            revert KipuBank_ZeroAmountError(context);
        }
        _;
    }

    /** @notice Ensures that the user has sufficient balance */
    modifier checkSufficientBalance(address user, address token, uint256 amount) {
        if (_userBalances[user][token] < amount) {
            revert KipuBank_InsufficientBalance(token, amount, _userBalances[user][token]);
        }
        _;
    }

    /** @notice Allows execution only if contract is not paused or caller is admin */
    modifier NotPausedOrAdmin() {
        if (paused() && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert KipuBank_ContractPaused();
        }
        _;
    }

    /** @notice Restricts function access to accounts with either the Admin or Manager role. */
    modifier onlyAdminOrManager() {
        if (!(hasRole(ADMIN_ROLE, msg.sender) || hasRole(MANAGER_ROLE, msg.sender))) {
            revert KipuBank_Unauthorized();
        }
        _;
    }

    /** @notice Ensures that the token is supported */
    modifier checkSupportedToken(address token) {
        if (address(tokens[token].priceFeed) == address(0)) {
            revert KipuBank_UnsupportedToken("Token is not supported",token);
        }
        _;
    }

    /**  @notice Ensures an address is not the zero address */
    modifier checkAddress(address addr) {
        if (addr == address(0)) {
            revert KipuBank_InvalidAddress(addr);
        }
        _;
    }

    /** @notice Ensures an address is a deployed contract */
    modifier checkContract(address addr) {
        uint256 codeSize;
        assembly { codeSize := extcodesize(addr) }
        if (codeSize == 0) {
            revert KipuBank_InvalidContract(addr);
        }
        _;
    }

    /** @notice Ensures a Chainlink price feed is valid and active */
    modifier checkPriceFeed(address priceFeed) {
        // Attempt to get latest price
        try AggregatorV3Interface(priceFeed).latestRoundData() returns (
            uint80, int256 price, uint256, uint256 updatedAt, uint80
        ) {
            if (price <= 0) {
                revert KipuBank_PriceFeedError("Price is zero or negative", priceFeed);
            }
            if (block.timestamp - updatedAt > ORACLE_HEARTEBAT) {
                revert KipuBank_PriceFeedError("Price feed is stale", priceFeed);
            }
        } catch {
            revert KipuBank_PriceFeedError("Failed to fetch price from feed", priceFeed);
        }
        _;
    }

    /** @notice Ensures that the provided address corresponds to a valid ERC-20 token. */
    modifier checkERC20(address token) {
        // Verify that the contract behaves like an ERC-20 (responds to totalSupply)
        try IERC20(token).totalSupply() returns (uint256) {
            // Valid ERC-20 contract
        } catch {
            revert KipuBank_InvalidToken("Invalid ERC-20 token");
        }
        _;
    }

    /** @notice Ensures that a token has a valid number of decimals */
    modifier checkDecimals(uint8 decimals) {
        if (decimals > 24) {
            revert KipuBank_InvalidTokenDecimals(decimals);
    }
    _;   
    }

    // ================= CONSTRUCTOR ================= //
    /**
     * @notice Initializes the bank with  bank cap and USD withdrawal limit
     * @param _bankCapUSD Maximum bank capacity in USD
     * @param _withdrawalLimitUSD Max USD withdrawal per transaction
     */
    constructor(uint256 _bankCapUSD, uint256 _withdrawalLimitUSD, address _ETHpriceFeed)
        checkNonZero(_bankCapUSD, "Bank capacity USD")
        checkNonZero(_withdrawalLimitUSD, "USD withdrawal limit")
    {
        bankCapUSD = _bankCapUSD;
        withdrawalLimitUSD = _withdrawalLimitUSD;
        tokens[address(0)].decimals = 18; //ETH is always supported
        tokens[address(0)].priceFeed = AggregatorV3Interface(_ETHpriceFeed);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // ================= DEPOSIT / WITHDRAW ================= //
    /**
     * @notice Deposit native ETH into the bank.
     * @dev 
     * - Uses `msg.value` as the deposited amount.
     * - Converts the deposited ETH to its USD equivalent using Chainlink price feeds.
     * - Reverts if the deposit exceeds the total bank capacity in USD.
     * - Emits a {KipuBank_DepositMade} event on success.
     */
    function depositETH()
        external
        payable
        NotPausedOrAdmin
        checkNonZero(msg.value, "ETH deposit")
    {
        uint256 amount = msg.value;
        uint256 amountUSD = _convertToUSD(address(0), amount);
        if (amountUSD + currentTotalUSD > bankCapUSD) {
            revert KipuBank_BankCapacityExceeded(amountUSD, bankCapUSD -  currentTotalUSD);
        }
        _depositETH(amount, amountUSD);
        emit KipuBank_DepositMade(msg.sender, address(0), amount, _userBalances[msg.sender][address(0)], amountUSD);
    }

    /**
     * @notice Deposit ERC-20 tokens into the bank.
     * @dev 
     * - Transfers the specified `amount` of tokens from the caller to the contract.
     * - Converts the deposited token amount to USD using the token's Chainlink feed.
     * - Reverts if:
     *    - The token is not supported.
     *    - The deposit amount exceeds the bank's capacity in USD.
     * - Emits a {KipuBank_DepositMade} event on success.
     * @param token Address of the ERC-20 token to deposit.
     * @param amount Amount of tokens to deposit, in token decimals.
     */
    function depositToken(address token, uint256 amount)
        external
        NotPausedOrAdmin
        checkSupportedToken(token)
        checkNonZero(amount, "Token deposit")
    {
        uint256 amountUSD = _convertToUSD(token, amount);
        if (amountUSD + currentTotalUSD > bankCapUSD) {
            revert KipuBank_BankCapacityExceeded(amountUSD, bankCapUSD - currentTotalUSD);
        }
        _depositERC20(token, amount, amountUSD);
        emit KipuBank_DepositMade(msg.sender, token, amount, _userBalances[msg.sender][token], amountUSD);
    }


    /**
     * @notice Withdraw ETH or ERC-20 tokens
     * @param token Token address (0 for ETH)
     * @param amount Amount to withdraw
     */
    function withdraw(address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        checkSupportedToken(token)
        checkNonZero(amount, "Withdrawal amount")
        checkSufficientBalance(msg.sender, token, amount)
    {
        uint256 amountUSD = _convertToUSD(token, amount); 
        if (amountUSD > withdrawalLimitUSD) {
            revert KipuBank_WithdrawalLimitExceeded(token, amount, amountUSD, withdrawalLimitUSD);
        }
        if(token == address(0)) 
            _withdrawETH(amount, amountUSD);
        else 
            _withdrawERC20(token, amount, amountUSD);
        emit KipuBank_WithdrawalMade(msg.sender ,token, amount, _userBalances[msg.sender][token], amountUSD);
    }

    // ================= ADMIN FUNCTIONS ================= //
    /**
    * @notice Adds support for a new ERC-20 token to the bank.
    * @dev The token must have a valid Chainlink price feed. Manual price updates are not allowed.
    *      Reverts if the feed is invalid or stale.
    * @param token Address of the ERC-20 token.
    * @param tokenDecimal Number of decimals of the token.
    * @param tokenPriceFeed Address of the Chainlink price feed for the token.
    */
    function addToken(address token, uint8 tokenDecimal,address tokenPriceFeed)
        external
        onlyRole(ADMIN_ROLE)
        checkAddress(tokenPriceFeed)
        checkContract(tokenPriceFeed)
        checkPriceFeed(tokenPriceFeed)      
        checkERC20(token)
        checkDecimals(tokenDecimal)
    {
        if(this.isTokenSupported(token)) {
            revert KipuBank_UnsupportedToken("Token already supported",token);
        }
        tokens[token].priceFeed = AggregatorV3Interface(tokenPriceFeed);
        tokens[token].decimals = tokenDecimal;
        emit KipuBank_TokenAdded(token, tokenDecimal);
    }

    /**
    * @notice Removes support for a token from the bank.
    * @dev Only admin can call this function. The token must have zero total balance in the bank.
    * @param token Address of the ERC-20 token to remove.
    */
    function removeToken(address token) external 
        onlyRole(ADMIN_ROLE) 
        checkSupportedToken(token) 
    {
        if(tokens[token].totalBalance > 0) {
            revert KipuBank_NonZeroBalance(token, tokens[token].totalBalance);
        }
        if(token == address(0)) {
            revert KipuBank_UnsupportedToken("Cannot remove ETH", token);
        }
        delete tokens[token];
        emit KipuBank_TokenRemoved(token);
    }

    /**
    * @notice Updates the Chainlink price feed address for a specific token.
    * @dev Only admin can call this. Token must be supported.
    * @param token Address of the token.
    * @param newPriceFeed Address of the new Chainlink price feed.
    */
    function setTokenPriceFeed(address token, address newPriceFeed)
        external
        onlyAdminOrManager
        checkSupportedToken(token) 
        checkAddress(newPriceFeed)
        checkContract(newPriceFeed)
        checkPriceFeed(newPriceFeed)
    {
        tokens[token].priceFeed = AggregatorV3Interface(newPriceFeed);
        emit KipuBank_PriceFeedUpdated(token, newPriceFeed, block.timestamp);
    }

    /**
     * @notice Update global bank capacity in USD
     * @param newBankCapUSD New capacity
     */
    function setBankCap(uint256 newBankCapUSD)
        external
        onlyRole(ADMIN_ROLE)
        checkNonZero(newBankCapUSD, "New bank capacity USD")
    {
        bankCapUSD = newBankCapUSD;
        emit KipuBank_BankCapUpdated(newBankCapUSD);
    }

    /**
    * @notice Updates the maximum allowed withdrawal per transaction in USD.
    * @param newWithdrawalLimitUSD The new withdrawal limit in USD .
    */
    function setWithdrawalLimit(uint256 newWithdrawalLimitUSD)
        external
        onlyAdminOrManager
        checkNonZero(newWithdrawalLimitUSD, "New withdrawal USD")
    {
        withdrawalLimitUSD = newWithdrawalLimitUSD;
        emit KipuBank_WithdrawalUpdated(newWithdrawalLimitUSD);
    }


    // ================= PAUSABLE ================= //
    /**
    * @notice Pauses all contract operations that are pausable.
    */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit KipuBank_Paused(msg.sender, block.timestamp);
    }

    /**
    * @notice Unpauses the contract, allowing operations to resume.
    */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit KipuBank_Unpaused(msg.sender, block.timestamp);
    }

    // ================= VIEW FUNCTIONS ================= //
    /**
    * @param user Address of the user.
    * @param token Address of the token (use address(0) for ETH).
    * @return balance The user's balance in the token's native decimals.
    */
    function getBalance(address user, address token) external view returns (uint256) {
        return _userBalances[user][token];
    }

    /**
     * @dev A token is considered supported if it has a valid Chainlink price feed assigned.
     * @param token The address of the token to check.
     * @return isSupported True if the token is supported, false otherwise.
     */
    function isTokenSupported(address token) external view returns (bool) {
        return address(tokens[token].priceFeed) != address(0);
    }


    // ================= INTERNAL FUNCTIONS ================= //
    /**
    * @notice Converts a given token amount to its USD value using the latest Chainlink price feed.
    * @param token Address of the ERC-20 token (use address(0) for ETH).
    * @param amount Amount in the token's native decimals.
    * @return usdValue USD value of the amount with 8 decimals.
    * @dev Reverts if the token is not supported or its price feed is invalid/stale.
    */
    function _convertToUSD(address token, uint256 amount) internal view returns (uint256 usdValue) {
        uint256 tokenPrice = _getPriceFromOracle(token);
        uint8 decimals = tokens[token].decimals;           
        // Safe multiplication & division: (amount * tokenPrice) / 10**decimals
        usdValue = Math.mulDiv(amount, tokenPrice, 10 ** decimals);
    }
    
    /**
    * @notice Deposits ETH into the bank.
    * @param amount Amount of ETH to deposit (in wei).
    * @dev Updates the user's balance, total bank balance, and currentTotalUSD.
    */
    function _depositETH(uint256 amount, uint256 amountUSD) internal {
        _updateBalance(msg.sender, address(0), amount, false);
        tokens[address(0)].totalBalance += amount;
        currentTotalUSD += amountUSD;
        unchecked { depositCount++; }
    }

    /**
    * @notice Deposits ERC-20 tokens into the bank.
    * @param token Address of the ERC-20 token.
    * @param amount Amount of tokens to deposit (in token's decimals).
    * @dev Updates the user's balance, total bank balance, and currentTotalUSD.
    */
    function _depositERC20(address token, uint256 amount, uint256 amountUSD) internal {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _updateBalance(msg.sender, token, amount, false);
        tokens[token].totalBalance += amount;
        currentTotalUSD += amountUSD;
        unchecked { depositCount++; }
    }

    /** 
    * @notice Withdraws ETH from the bank.
    * @param amount Amount of ETH to withdraw (in wei).
    * @dev Updates balances and sends ETH to the user using a safe call.
    *      Reverts with {KipuBank_TransferFailed} if the transfer fails.
    */
    function _withdrawETH(uint256 amount, uint256 amountUSD) internal {
        _updateBalance(msg.sender, address(0), amount, true);
        tokens[address(0)].totalBalance -= amount;
        currentTotalUSD -= amountUSD;
        unchecked { withdrawalCount++; }
        console.log(msg.sender);
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            revert KipuBank_TransferFailed(address(0), msg.sender, amount);
        }
    }

    /**
    * @notice Withdraws ERC-20 tokens from the bank.
    * @param token Address of the ERC-20 token.
    * @param amount Amount to withdraw (in token's decimals).
    * @dev Updates balances and Transfers tokens to the user.
    */
    function _withdrawERC20(address token, uint256 amount, uint256 amountUSD) internal {
        _updateBalance(msg.sender, token, amount, true);
        tokens[token].totalBalance -= amount;
        currentTotalUSD -= amountUSD;
        unchecked { withdrawalCount++; }
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /**
    * @notice Retrieves the latest price of a token from its Chainlink feed.
    * @param token ERC-20 token address.
    * @return tokenPrice Price of the token in USD with 8 decimals.
    */
    function _getPriceFromOracle(address token) internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = tokens[token].priceFeed.latestRoundData();
        if (price <= 0 || updatedAt < block.timestamp - ORACLE_HEARTEBAT) {
            revert KipuBank_PriceFeedError("Invalid or stale price", address(tokens[token].priceFeed));
        }
        return uint256(price);
    }

    /**
    * @notice Updates the balance of a user for a specific token.
    * @param user User address.
    * @param token Token address.
    * @param amount Amount to add or subtract.
    * @param isWithdrawal True if subtracting (withdrawal), false if adding (deposit).
    */
    function _updateBalance(address user, address token, uint256 amount, bool isWithdrawal) private {
        if(isWithdrawal)
            _userBalances[user][token] -= amount;
        else 
            _userBalances[user][token] += amount;
    }

    // ================= RECEIVE ================= //
    /**
    * @notice Receives ETH sent to the contract and deposits it automatically.
    * @dev Calls `deposit(address(0), msg.value)` internally.
    */
    receive() external payable {
        this.depositETH();
    }
}
