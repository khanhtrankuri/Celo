# 💸 Remittance dApp

**Remittance dApp** is a decentralized application (dApp) that allows **users to transfer money across borders using stablecoins** (e.g. **cUSD** on the **Celo** network) **quickly, securely, and at low cost**, **without the need for a bank intermediary**.

The project aims for **financial inclusion** — enabling users anywhere to **send and receive money with just their mobile phone and a digital wallet** (MetaMask or Celo Wallet).

---

## 🚀 Highlights

| 🔹 | Features | Description |
|----|----------|-------|
| 🔒 | **Escrow Smart Contract** | Hold funds temporarily in the contract, only release when the recipient enters the correct **secret code** or when the **deadline**. |
| 💸 | **Cross-border money transfer** | Based on **stablecoins (cUSD, USDC)** – high speed, low fees, transparent and bank-independent. |
| 🧾 | **Refund** | The sender can refund the money if the recipient does not withdraw within the specified time. |
| 🛡️ | **High security** | The contract supports **SafeERC20**, **anti-Reentrancy Attack** mechanism. |
| ⚙️ | **Flexible fees** | The contract owner can customize the **fee rate (feeBps ≤ 10000)** when the recipient withdraws. |

---

## 🧠 System Architecture

Here is a diagram that describes how the **Remittance dApp** works between the sender, smart contract, and receiver:

                 ┌────────────────────────────┐
                 │      💸 Remittance dApp    │
                 └────────────────────────────┘
                              │
                              │
      ┌──────────────────────────────────────────────────┐
      │                    Smart Contract                │
      │──────────────────────────────────────────────────│
      │                                                  │
      │  1️⃣ deposit(token, amount, recipient, deadline)  │
      │  2️⃣ claim(secret)                                │
      │  3️⃣ refund(id)                                   │
      │                                                  │
      └──────────────────────────────────────────────────┘
             ▲                                 │
             │                                 │
     refund()│                                 │claim()
             │                                 ▼
    ┌─────────────────┐              ┌─────────────────┐
    │ 👤 Sender       │             │ 👤 Recipient    │
    │                 │              │                 │
    └─────────────────┘              └─────────────────┘
             │
             │ deposit()
             ▼
      ┌────────────────────────────┐
      │ 💼 Escrow (Token Vault)    │
      │ - Secure token storage     │
      │ - Release only when valid  │
      └────────────────────────────┘


**Workflow:**

1. **Sender** creates `secret` and calculates `secretHash = keccak256(abi.encodePacked(secret, recipient))`.

2. **Deposit**: Sender calls `deposit()` with token, recipient, deadline and `secretHash`.
3. **Recipient** calls `claim(secret)` with correct secret → receive money.
4. **If the deadline is overdue**, the sender can call `refund()` to get the money back.
5. When `claim()` is successful, the system automatically deducts **feeBps** for the owner.

---

## ⚙️ Main functions

| Function | Role | Note |
|-----|---------|---------|
| `deposit(token, amount, recipient, deadline, secretHash)` | Sender deposits funds into escrow | Supports ERC20 tokens (cUSD, USDC, USDT...) |
| `claim(id, secret)` | Recipient withdraws funds using secret code | Check hash: `keccak256(abi.encodePacked(secret, recipient))` |
| `refund(id)` | Sender refunds after deadline | Only possible after `deadline` passed |
| `setFeeBps(newFee)` | Contract owner changes fee rate | `feeBps ≤ 10000` |
| `transferOwnership(newOwner)` | Transfers contract administration rights | Only `owner` is allowed to call |

---

Celo Sepolia Testnet : 0xfad4da6779add9459b7743cf73e2f17ae583c631




