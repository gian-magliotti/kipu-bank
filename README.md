###### \# **KipuBank**





KipuBank is a decentralized smart contract bank written in Solidity that allows users to deposit and withdraw ETH as well as multiple ERC-20 tokens.  



This \*\***second version (v2)**\*\* introduces significant improvements over a basic ETH vault, including multi-token support, USD value tracking via Chainlink price feeds, enhanced security with role-based access control and reentrancy protection, and configurable global and per-withdrawal limits.  



Users can now safely interact with ETH and a growing list of ERC-20 tokens, while the contract enforces limits and protections to maintain the bank's liquidity and security.



---



###### \## 🌟 **High-Level Improvements**



1\. **Multi-token support**

   - Users can now deposit and withdraw ERC-20 tokens, not just ETH.

   - Each token is tracked individually with its own Chainlink price feed.



2\. **USD value tracking**

   - All deposits and withdrawals are converted to USD using Chainlink oracles.

   - Enables enforcing global bank capacity and per-transaction withdrawal limits in USD rather than raw token amounts.



3\. **Role-based access control**

   - Admin, Manager, and Pauser roles improve security and operational flexibility.



4\. **Enhanced security**

   - `ReentrancyGuard` prevents reentrancy attacks.

   - Pausable functionality allows emergency stops.

   - Detailed custom errors improve debugging and reduce gas costs compared to `require` statements.



5\. **Stale price protection**

   - Deposits and withdrawals revert if the Chainlink price feed is older than 1 hour, preventing manipulation with outdated prices.



---

###### ⚠️ **Custom Errors**



Some of the most important ones are:



 - KipuBank\_BankCapacityExceeded(requestedUSD, availableUSD)



 - KipuBank\_WithdrawalLimitExceeded(token, requestedAmount, requestedUSD, limitUSD)



 - KipuBank\_InsufficientBalance(token, requested, available)



 - KipuBank\_ZeroAmountError(context)



 - KipuBank\_TransferFailed(token, user, amount)



 - KipuBank\_PriceFeedError(msg, feedAddress)



These provide clear, gas-efficient failure messages for users and developers.



###### 📝 **Design Decisions \& Trade-offs**



**1. Chainlink price feeds for USD conversion**



  - Ensures consistent USD valuation across tokens.



  - Trade-off: reliance on external oracles; contract cannot function if feeds fail.



**2. Global bank cap and per-withdrawal limits**



  - Protects against excessive risk and enforces liquidity constraints.



  - Trade-off: limits flexibility for users with large holdings.



**3. Role-based access control**



  - Fine-grained permissioning reduces admin risk.



  - Trade-off: Slightly more complex to maintain roles and manage events.



**4. Use of custom errors instead of require()**



  - Reduces gas cost for failed transactions.



  - Trade-off: slightly higher initial complexity in contract readability.



**5. ERC-20 token support with decimals**



  - Supports many tokens reliably.



  - Trade-off: requires careful management of token decimal differences and price feed accuracy.

###### 

###### \## ⚙️ **Deployment \& Interaction**



\### **Option 1: Remix IDE (Quick)**



1\. Open \[Remix IDE](https://remix.ethereum.org/) and create `KipuBank.sol`



2\. Paste the contract code and compile with Solidity 0.8.30.



3\. In \*\*Deploy \& Run Transactions\*\*:

&nbsp;  - Environment: \*\*Remix VM\*\* (local) or \*\*Injected Provider\*\* (MetaMask/testnet).

&nbsp;  - Constructor parameters:

&nbsp;    - `\_bankCapUSD` → total USD capacity of the bank.

&nbsp;    - `\_withdrawalLimitUSD` → maximum USD per withdrawal.

&nbsp;    - `\_ETHpriceFeed` → Chainlink ETH/USD price feed address.



4\. Deploy and copy the contract address for interactions.



\### **Option 2: ethers.js (Node.js)**



\- Requirements: Node.js >=18, ethers.js, and a network RPC (Ganache, Hardhat, Infura, Alchemy, etc.).

\- Set `.env` file:
   RPC\_URL=https://sepolia.infura.io/v3/YOUR\_PROJECT\_ID
   PRIVATE\_KEY=0xYOUR\_PRIVATE\_KEY

&nbsp;  CONTRACT\_ADDRESS=0xDEPLOYED\_CONTRACT\_ADDRESS



