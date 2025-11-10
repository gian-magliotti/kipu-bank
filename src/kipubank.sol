// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


// ================== INTERFACES ==================
/** @notice Minimal WETH interface (adds deposit/withdraw) */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title KipuBank
 * @notice A decentralized smart contract bank that allows users to deposit ETH or supported ERC-20 tokens,
 *         which are automatically swapped to USDC via Uniswap V2.
 *         - Maintains user balances in USDC as the base asset.
 *         - Enforces a global bank capacity and per-withdrawal USDC limits.
 *         - Supports dynamic addition and removal of supported tokens.
 *         - Implements role-based access control with Admin, Manager, and Pauser roles.
 *         - Features pausable operations, reentrancy protection, and comprehensive custom errors.
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

    /** 
    * @notice The base token of the bank. 
    * @dev All deposits and swaps are ultimately converted to this token (USDC). 
    */
    IERC20 public immutable USDC;

    /**
    * @notice The Uniswap V2 factory contract.
    * @dev Used to fetch pair addresses for token swaps. 
    */
    IUniswapV2Factory public immutable FACTORY;

    /**  @notice The WETH contract (wrapped ETH) used for handling native ETH swaps.  */
    IWETH public immutable WETH;

    /** @notice Special address used to represent Ether (ETH) instead of an ERC20 token. */
    address internal constant ETH = address(0);

    // ================== STRUCTS ==================
    /** @notice Structure to return token info. */
    struct TokenInfo {
        address tokenAddress;
        string symbol;
    }

    // ================= STATE VARIABLES ================= //
    /** @notice Total bank capacity in USDC. */
    uint256 public bankCapUSDC;

    /** @notice Current bank total in USDC. */
    uint256 public currentTotalUSDC;

    /** @notice User balances in USDC. */
    mapping(address => uint256) private _userBalances;

    /** @notice Max withdrawal in USDC. */
    uint256 public withdrawalLimitUSDC;

    /** @notice Number of deposits. */
    uint256 public depositCount;

    /** @notice Number of withdrawals. */
    uint256 public withdrawalCount;

    /** @notice Array of supported tokens. This array allows us to enumerate all supported tokens */
    address[] private supportedTokens;

    /** @notice Mapping to check if a token has already been added.  This provides a fast O(1) lookup to prevent duplicates  */
    mapping(address => bool) private isSupported;

    // ================= EVENTS ================= //
    /** @notice Emitted when a deposit is made */
    event KipuBank_DepositMade(address indexed user, address indexed token, uint256 amount, uint256 newBalance);

    /** @notice Emitted when a withdrawal is made */
    event KipuBank_WithdrawalMade(address indexed user, uint256 amount, uint256 newBalance);

    /** @notice Emitted when a new token is supported */
    event KipuBank_TokenAdded(address indexed token, string symbol);

    /** @notice Emitted when a token is removed from the bank. */
    event KipuBank_TokenRemoved(address indexed token, string symbol);

    /** @notice Emitted when bank cap USDC is updated */
    event KipuBank_BankCapUpdated(uint256 newBankCapUSD);

    /** @notice Emitted when withdrawal USDC is updated */
    event KipuBank_WithdrawalUpdated(uint256 newWithdrawalUSD);

    /** @notice Emitted when contract is paused */
    event KipuBank_Paused(address indexed account, uint256 timestamp);

    /** @notice Emitted when contract is unpaused */
    event KipuBank_Unpaused(address indexed account, uint256 timestamp);

    // ================= ERRORS ================= //
    /** @notice Emitted when bank capacity is exceeded */
    error KipuBank_BankCapacityExceeded(uint256 requestedAmountUSDC, uint256 availableCapacityUSDC);

    /** @notice Emitted when withdrawal exceeds limit */
    error KipuBank_WithdrawalLimitExceeded(uint256 requestedAmountUSDC, uint256 withdrawalLimitUSDC);

    /** @notice Emitted when user balance is insufficient */
    error KipuBank_InsufficientBalance(uint256 requestedAmountUSDC, uint256 availableBalanceUSDC);

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

    /** @notice Error thrown when a Uniswap V2 pair does not exist for the given token addresses.*/
    error KipuBank_PairDoesNotExist();

    /** @notice Revert error when a token swap produces less output than expected. */
    error KipuBank_InsufficientOutputAmount();

    /** @notice Revert error when a swap cannot be performed due to lack of liquidity. */
    error KipuBank_InsufficientLiquidity();

    /** @notice Thrown when the output amount after a swap is below the minimum acceptable value (slippage protection). */
    error KipuBank_SlippageExceeded();

    // ================= MODIFIERS ================= //
    /** @notice Ensures that the amount is non-zero */
    modifier checkNonZero(uint256 amount, string memory context) {
        if(amount == 0) {
            revert KipuBank_ZeroAmountError(context);
        }
        _;
    }

    /** @notice Ensures that the user has sufficient balance */
    modifier checkSufficientBalance(address user, uint256 amount) {
        if (_userBalances[user] < amount) {
            revert KipuBank_InsufficientBalance(amount, _userBalances[user]);
        }
        _;
    }

    /** @notice Ensures that the user does not exceed withdrawal limit */
    modifier checkWithdrawalLimit(uint256 amount) {
        if (amount > withdrawalLimitUSDC) {
            revert KipuBank_WithdrawalLimitExceeded(amount, withdrawalLimitUSDC);
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
        if (!isSupported[token]) {
            revert KipuBank_UnsupportedToken("Token is not supported", token);
        }
        _;
    }

    /** @notice Ensures an address is not the zero address */
    modifier checkAddress(address addr) {
        if (addr == ETH) {
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

    /** @notice Validates that the token pair exists in the factory */
    modifier pairExists(address tokenA, address tokenB) {
        address pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            revert KipuBank_PairDoesNotExist();
        }
        _;
    }

    // ================= CONSTRUCTOR ================= //
    /**
    * @notice Initializes the KipuBankV3 contract.
    * @dev Sets bank capacity, withdrawal limit, USDC token, Uniswap V2 factory and WETH.
    *      Grants ADMIN_ROLE and PAUSER_ROLE to the deployer.
    * @param _bankCapUSDC Maximum total USDC the bank can hold.
    * @param _withdrawalLimitUSDC Maximum USDC a user can withdraw at once.
    * @param _factory Address of the Uniswap V2 factory contract.
    * @param _USDC Address of the USDC token used as the base currency.
    * @param _weth Address of the WETH token (wrapped ETH).
    */
    constructor(uint256 _bankCapUSDC, uint256 _withdrawalLimitUSDC, address _factory, address _USDC, address _weth)
        checkNonZero(_bankCapUSDC, "Bank capacity USD")
        checkNonZero(_withdrawalLimitUSDC, "USD withdrawal limit")
        checkERC20(_USDC)
        checkERC20(_weth)
    {
        bankCapUSDC = _bankCapUSDC;
        withdrawalLimitUSDC = _withdrawalLimitUSDC;
        USDC = IERC20(_USDC);
        FACTORY = IUniswapV2Factory(_factory);
        WETH = IWETH(_weth);
        isSupported[_USDC] = true;
        supportedTokens.push(_USDC);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // ================= DEPOSIT / WITHDRAW ================= //
    /**
    * @notice Deposits ETH into the bank, swaps it to USDC internally, and updates user balance.
    * @dev Respects bankCapUSDC. Uses internal _updateBalance().
    * @dev Requires contract not paused or caller to be admin.
    */
    function depositETH()
        public
        payable
        NotPausedOrAdmin
        nonReentrant
        checkNonZero(msg.value, "ETH deposit")
    {
        uint256 amount = msg.value;

        // Convert ETH to USDC using internal swap function
        uint256 amountUSDC = _swapToUSDC(ETH, amount);

        // Check bank cap
        if (amountUSDC + currentTotalUSDC > bankCapUSDC) {
            revert KipuBank_BankCapacityExceeded(amountUSDC, bankCapUSDC - currentTotalUSDC);
        }

        // Update balances
        _updateBalance(msg.sender, amountUSDC, false);
        currentTotalUSDC += amountUSDC;
        unchecked{ depositCount ++;}

        emit KipuBank_DepositMade(msg.sender, ETH, amount, _userBalances[msg.sender]);
    }

    /**
    * @notice Deposits a supported ERC20 token into the bank, swaps to USDC internally, and updates user balance.
    * @param token Address of the ERC20 token to deposit
    * @param amount Amount of the token to deposit
    * @dev Respects bankCapUSDC. Uses internal _updateBalance().
    * @dev Requires contract not paused or caller to be admin.
    */
    function depositToken(address token, uint256 amount)
        external
        NotPausedOrAdmin
        nonReentrant
        checkSupportedToken(token)
        checkNonZero(amount, "Token deposit")
    {
        uint256 amountUSDC;

        if (token == address(USDC)) {
            // If USDC, no swap needed
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
            amountUSDC = amount;
        } else {
            // Swap token to USDC internally
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            amountUSDC = _swapToUSDC(token, amount);
        }

        // Check bank cap
        if (amountUSDC + currentTotalUSDC > bankCapUSDC) {
            revert KipuBank_BankCapacityExceeded(amountUSDC, bankCapUSDC - currentTotalUSDC);
        }

        // Update balances
        _updateBalance(msg.sender, amountUSDC, false);
        currentTotalUSDC += amountUSDC;
        unchecked{ depositCount ++;}
        emit KipuBank_DepositMade(msg.sender, token, amount, _userBalances[msg.sender]);
    }

    /**
    * @notice Allows users to withdraw their USDC balance from the bank.
    * @param amountUSDC The amount of USDC to withdraw.
    */
    function withdraw(uint256 amountUSDC)
        external
        nonReentrant
        NotPausedOrAdmin
        checkNonZero(amountUSDC, "Withdraw amount")
        checkWithdrawalLimit(amountUSDC)
        checkSufficientBalance(msg.sender, amountUSDC)
    {
        // Update balances before transferring tokens (Checks-Effects-Interactions)
        _updateBalance(msg.sender, amountUSDC, true);
        currentTotalUSDC -= amountUSDC;
        unchecked { withdrawalCount++; }

        // Transfer USDC to the user
        IERC20(USDC).safeTransfer(msg.sender, amountUSDC);

        emit KipuBank_WithdrawalMade(msg.sender, amountUSDC, _userBalances[msg.sender]);
    }

    // ================= ADMIN FUNCTIONS ================= //
    /**
    * @notice Adds a new ERC20 token to the list of supported tokens.
    * @dev Only accounts with ADMIN_ROLE can call this function.
    *      The token must be a valid ERC20 and have a Uniswap V2 pair with USDC.
    * @param token The address of the ERC20 token to add.
    * @custom:reverts KipuBank_UnsupportedToken if the token is already supported.
    * @custom:reverts KipuBank_PairDoesNotExist if no Uniswap V2 pair exists with USDC.
    */
    function addToken(address token)
        external
        onlyRole(ADMIN_ROLE)
        checkERC20(token)
        pairExists(token, address(USDC))
    {
        if (isSupported[token]) {
            revert KipuBank_UnsupportedToken("Token already supported", token);
        }
        supportedTokens.push(token);
        isSupported[token] = true;
        string memory symbol = IERC20Metadata(token).symbol();
        emit KipuBank_TokenAdded(token, symbol);
    }

    /**
    * @notice Removes a supported token from the bank.
    * @dev Only ADMIN_ROLE can call this function.
    *      ETH (address 0) and the base token (USDC) cannot be removed.
    *      The token is removed from both the mapping and the array to maintain consistency.
    * @param token The address of the token to remove.
    * @custom:reverts KipuBank_UnsupportedToken if the token is ETH (address 0), USDC, or not supported.
    * @custom:emits KipuBank_TokenRemoved when the token is successfully removed.
    */
    function removeToken(address token)
        external
        onlyRole(ADMIN_ROLE)
        checkSupportedToken(token)
    {
        // Prevent removing ETH or the base token (USDC)
        if (token == ETH || token == address(USDC)) {
            revert KipuBank_UnsupportedToken("Cannot remove ETH or USDC", token);
        }
        isSupported[token] = false;
        // Remove token from array (swap & pop for gas efficiency)
        uint256 length = supportedTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[length - 1];
                supportedTokens.pop();
                break;
            }
        }
        string memory symbol = IERC20Metadata(token).symbol();
        emit KipuBank_TokenRemoved(token, symbol);
    }

    /**
    * @notice Update global bank capacity in USDC
    * @param newBankCapUSD New capacity
    */
    function setBankCap(uint256 newBankCapUSD)
        external
        onlyRole(ADMIN_ROLE)
        checkNonZero(newBankCapUSD, "New bank capacity USD")
    {
        bankCapUSDC = newBankCapUSD;
        emit KipuBank_BankCapUpdated(newBankCapUSD);
    }

    /**
    * @notice Updates the maximum allowed withdrawal per transaction in USDC.
    * @param  newWithdrawalLimitUSDC The new withdrawal limit in USDC.
    */
    function setWithdrawalLimit(uint256 newWithdrawalLimitUSDC)
        external
        onlyAdminOrManager
        checkNonZero(newWithdrawalLimitUSDC, "New withdrawal USD")
    {
        withdrawalLimitUSDC = newWithdrawalLimitUSDC;
        emit KipuBank_WithdrawalUpdated(newWithdrawalLimitUSDC);
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
    * @return balance The user's balance in USDC.
    */
    function getBalance(address user) external view returns (uint256) {
        return _userBalances[user];
    }

    /**
     * @param token The address of the token to check.
     * @return supported True if the token is supported, false otherwise.
     */
    function isTokenSupported(address token) external view returns (bool) {
        return isSupported[token];
    }

    /**
    * @notice Returns a list of all supported tokens with their addresses and symbols
    * @return tokensInfo An array of TokenInfo containing address and symbol for each supported token
    */
    function getSupportedTokens() external view returns (TokenInfo[] memory tokensInfo) {
        uint256 length = supportedTokens.length;
        tokensInfo = new TokenInfo[](length);
        for (uint256 i = 0; i < length; i++) {
            address tokenAddr = supportedTokens[i];
            string memory symbol;
            try IERC20Metadata(tokenAddr).symbol() returns (string memory sym) {
                symbol = sym;
            } catch {
                symbol = ""; // fallback if symbol is not available
            }
            tokensInfo[i] = TokenInfo({
                tokenAddress: tokenAddr,
                symbol: symbol
            });
        }
        return tokensInfo;
    }

    // ================= INTERNAL FUNCTIONS ================= //
    /**
    * @notice Internal helper to swap any token or ETH to USDC using Uniswap V2 pair-level swap.
    * @dev 
    *  - For ERC20 tokens, assumes `amountIn` was already transferred to this contract.
    *  - For ETH, the function wraps to WETH before performing the swap.
    *  - Performs a direct Uniswap V2 pair-level swap (no router).
    *  - The resulting USDC is sent back to this contract.
    * @param tokenIn The input token address. Use address(0) when depositing ETH.
    * @param amountIn The amount of input tokens to swap (in smallest units or wei).
    * @return amountOutUSDC The amount of USDC received after the swap.
    */
    function _swapToUSDC(address tokenIn, uint256 amountIn) internal returns (uint256 amountOutUSDC) {
        // If input is already USDC, no swap needed
        if (tokenIn == address(USDC)) {
            return amountIn;
        }

        // 1. Handle ETH -> WETH conversion
        address swapToken = tokenIn;
        uint256 swapAmount = amountIn;
        if (tokenIn == ETH) {
            // Wrap native ETH into WETH
            WETH.deposit{value: amountIn}();
            swapToken = address(WETH);
            swapAmount = IERC20(swapToken).balanceOf(address(this)); 
        }
        address pair = FACTORY.getPair(swapToken, address(USDC));

        // 2. Calculate expected output using Uniswap reserves
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(swapToken, pair);
        uint256 amountOutExpected = _getAmountOut(swapAmount, reserveIn, reserveOut);
        uint256 minAmountOut = (amountOutExpected * 995) / 1000; // 0.5% slippage tolerance

        // 3. Transfer tokens from this contract to the pair (required by Uniswap V2)
        IERC20(swapToken).safeTransfer(pair, swapAmount);

        // 4. Execute the swap on the Uniswap V2 pair
        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
        _swap(pair, swapToken, swapAmount);
        uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));

        // 5. Calculate how much USDC we received
        amountOutUSDC = balanceAfter - balanceBefore;

        // 6. Validate output and slippage
        if (amountOutUSDC == 0) revert KipuBank_InsufficientOutputAmount();
        if (amountOutUSDC < minAmountOut) revert KipuBank_SlippageExceeded();
    }

    /**
    * @notice Executes the low-level Uniswap V2 pair swap.
    * @dev 
    *  - Assumes the contract already sent `amountIn` of `tokenIn` to the pair.
    *  - This function determines which token is token0/token1 and calls swap accordingly.
    * @param pair The Uniswap V2 pair address.
    * @param tokenIn The input token address.
    * @param amountIn The exact input token amount that was just transferred to the pair.
    */
    function _swap(address pair, address tokenIn, uint256 amountIn) internal {
        // Get reserves for tokenIn/tokenOut
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(tokenIn, pair);

        // Compute output amount
        uint256 amountOutExpected = _getAmountOut(amountIn, reserveIn, reserveOut);

        // Determine token order in the pair
        address token0 = IUniswapV2Pair(pair).token0();
        bool token0IsTokenIn = token0 == tokenIn;

        // Define output amounts
        uint256 amount0Out = token0IsTokenIn ? 0 : amountOutExpected;
        uint256 amount1Out = token0IsTokenIn ? amountOutExpected : 0;

        // Execute the swap, sending USDC to this contract
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");
    }

    /**
    * @dev Gets reserves for a token pair, ordered correctly.
    */
    function _getReserves(address tokenIn, address pair)
        internal view returns (uint256 reserveIn, uint256 reserveOut)
    {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        if (token0 == tokenIn) {
            return (reserve0, reserve1);
        } else {
            return (reserve1, reserve0);
        }
    }

    /**
    * @notice Calculates the output amount of a Uniswap V2 swap given an exact input amount.
    * @dev Private helper using Uniswap V2 formula with 0.3% fee.
    */
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            revert KipuBank_InsufficientLiquidity();
        }

        // Apply Uniswap V2 0.3% fee
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        return numerator / denominator;
    }

    /**
    * @notice Updates the balance of a user for USDC.
    * @param user User address.
    * @param amount Amount to add or subtract.
    * @param isWithdrawal True if subtracting (withdrawal), false if adding (deposit).
    */
    function _updateBalance(address user, uint256 amount, bool isWithdrawal) private {
        if (isWithdrawal) {
            _userBalances[user] -= amount;
        } else {
            _userBalances[user] += amount;
        }
    }

    // ================= RECEIVE ================= //
    /**
    * @notice Receives ETH sent to the contract and deposits it automatically.
    * @dev Calls `depositETH()` internally so ETH transfers are treated as deposits.
    */
    receive() external payable {
        depositETH();
    }
}