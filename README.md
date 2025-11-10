# **KipuBank**

KipuBank is a decentralized smart contract bank written in Solidity that allows users to deposit and withdraw **ETH and supported ERC-20 tokens**, which are **automatically swapped to USDC** through **Uniswap V2**.

This **third version (v3)** significantly improves upon a basic ETH vault by introducing **automatic token conversion**, **multi-token support**, **centralized USDC accounting**, **enhanced role-based access control**, and **configurable security and liquidity constraints**.

Users can safely deposit ETH or other tokens, while all balances are internally managed in USDC.  
Withdrawals are performed in USDC, ensuring price stability and simplifying the enforcement of withdrawal and capacity limits.

---

## 🌟 **High-Level Improvements**

1. **Automatic conversion to USDC**
   - Deposits of ETH or ERC-20 tokens are instantly swapped to USDC using Uniswap V2.
   - All internal accounting and limits are based on USDC balances.

2. **Multi-token support**
   - Supports multiple ERC-20 tokens as deposit sources.
   - Tokens can be dynamically added or removed by authorized managers.

3. **Configurable liquidity limits**
   - Enforces both a **global bank capacity** (maximum total USDC equivalent) and **per-withdrawal limits**.
   - All limits are denominated in USDC for consistency and risk control.

4. **Role-based access control**
   - Fine-grained permissions via `AccessControl`:
     - **Admin** — full control over configuration and roles.
     - **Manager** — manages supported tokens and operational settings.
     - **Pauser** — can pause the contract in emergencies.

5. **Enhanced security**
   - `ReentrancyGuard` prevents reentrancy exploits.
   - `Pausable` allows halting critical operations.
   - `SafeERC20` ensures secure token transfers.
   - Comprehensive **custom errors** reduce gas and improve clarity.

6. **Comprehensive error handling**
   - Replaces `require()` statements with descriptive, gas-efficient custom errors for debugging and UX improvements.

---

## ⚠️ **Custom Errors**

Some of the most important ones are:

- `KipuBank_BankCapacityExceeded(requestedUSDC, availableUSDC)`
- `KipuBank_WithdrawalLimitExceeded(requestedAmount, requestedUSDC, limitUSDC)`
- `KipuBank_InsufficientBalance(requested, available)`
- `KipuBank_ZeroAmountError(context)`
- `KipuBank_TransferFailed(token, user, amount)`
- `KipuBank_SwapFailed(token, amountIn, reason)`

These provide clear, gas-efficient failure messages for users and developers.

---

## 📝 **Design Decisions & Trade-offs**

**1. USDC as the base currency**

- Simplifies valuation and limit enforcement.
- Provides stability and consistency.
- *Trade-off:* requires reliance on Uniswap liquidity for token conversion.

**2. Global and per-withdrawal caps**

- Protects liquidity and prevents over-withdrawals.
- *Trade-off:* may restrict large users during periods of high activity.

**3. Role-based access control**

- Separates administrative, managerial, and emergency privileges.
- *Trade-off:* Slightly increases operational complexity.

**4. Custom errors instead of require()**

- Lowers gas costs for failed transactions.
- *Trade-off:* Slightly increases code verbosity.

**5. Integration with Uniswap V2**

- Enables decentralized token-to-USDC swaps without intermediaries.
- *Trade-off:* introduces dependency on Uniswap router availability.

---

## ⚙️ **Deployment & Interaction**

### **Option 1: Remix IDE (Quick)**

1. Open [Remix IDE](https://remix.ethereum.org/) and create a new file `KipuBank.sol`.
2. Paste the contract code and compile with Solidity **v0.8.30**.
3. In **Deploy & Run Transactions**:
   - **Environment:** `Remix VM`, `Injected Provider` (MetaMask), or `Sepolia/Testnet`.
   - **Constructor parameters:**
     - `_bankCapUSDC` → total USDC capacity of the bank.
     - `_withdrawalLimitUSDC` → maximum USDC allowed per withdrawal.
     - `_uniswapRouter` → Uniswap V2 Router address (e.g., `0x...`).
     - `_USDC` → address of the USDC token contract.

4. Deploy and copy the contract address for interaction.

---

### **Option 2: Node.js (ethers.js)**

Requirements:
- Node.js ≥ 18
- `ethers.js`
- RPC provider (Infura, Alchemy, or local Hardhat node)

Create a `.env` file:
   RPC_URL=https://sepolia.infura.io/v3/YOUR_PROJECT_ID
   PRIVATE_KEY=0xYOUR_PRIVATE_KEY
   CONTRACT_ADDRESS=0xDEPLOYED_CONTRACT_ADDRESS


Example deployment script:
```javascript
import { ethers } from "ethers";
import fs from "fs";
import dotenv from "dotenv";
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

const abi = JSON.parse(fs.readFileSync("./KipuBank_abi.json"));
const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, abi, wallet);

(async () => {
  const tx = await contract.depositETH({ value: ethers.parseEther("1.0") });
  await tx.wait();
  console.log("Deposited 1 ETH successfully!");
})();
