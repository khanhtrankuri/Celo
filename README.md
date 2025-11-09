# 💸 Remittance dApp

**Remittance dApp** là một ứng dụng phi tập trung (dApp) cho phép **người dùng chuyển tiền xuyên biên giới bằng stablecoin** (ví dụ: **cUSD** trên mạng **Celo**) một cách **nhanh chóng, an toàn và chi phí thấp**, **không cần trung gian ngân hàng**.

Dự án hướng đến **mục tiêu tài chính toàn diện (financial inclusion)** — giúp người dùng ở bất kỳ đâu có thể **gửi và nhận tiền chỉ với điện thoại di động và ví điện tử** (MetaMask hoặc Celo Wallet).

---

## 🚀 Tính năng nổi bật

| 🔹 | Tính năng | Mô tả |
|----|-----------|-------|
| 🔒 | **Escrow Smart Contract** | Giữ tiền tạm thời trong hợp đồng, chỉ giải phóng khi người nhận nhập đúng **mã bí mật (secret)** hoặc khi **hết thời hạn (deadline)**. |
| 💸 | **Chuyển tiền xuyên biên giới** | Dựa trên **stablecoin (cUSD, USDC)** – tốc độ cao, phí thấp, minh bạch và không phụ thuộc vào ngân hàng. |
| 🧾 | **Refund (Hoàn tiền)** | Người gửi có thể hoàn lại tiền nếu người nhận không rút trong thời gian quy định. |
| 🛡️ | **Bảo mật cao** | Hợp đồng hỗ trợ **SafeERC20**, cơ chế **chống Reentrancy Attack**. |
| ⚙️ | **Phí linh hoạt** | Chủ sở hữu hợp đồng có thể tùy chỉnh **tỷ lệ phí (feeBps ≤ 10000)** khi người nhận rút tiền. |

---

## 🧠 Kiến trúc hệ thống

Dưới đây là sơ đồ mô tả cách **Remittance dApp** hoạt động giữa người gửi, hợp đồng thông minh và người nhận:

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
    │ 👤 Người gửi    │             │ 👤 Người nhận   │
    │ (Sender)        │              │ (Recipient)     │
    └─────────────────┘              └─────────────────┘
             │
             │ deposit()
             ▼
      ┌────────────────────────────┐
      │ 💼 Escrow (Token Vault)    │
      │ - Lưu trữ token an toàn    │
      │ - Chỉ giải phóng khi hợp lệ│
      └────────────────────────────┘


**Luồng hoạt động:**

1. **Người gửi (Sender)** tạo `secret` và tính `secretHash = keccak256(abi.encodePacked(secret, recipient))`.
2. **Gửi tiền (deposit)**: Người gửi gọi `deposit()` với token, người nhận, thời hạn và `secretHash`.
3. **Người nhận (Recipient)** gọi `claim(secret)` với đúng secret → nhận tiền.
4. **Nếu quá hạn (deadline)**, người gửi có thể gọi `refund()` để nhận lại tiền.
5. Khi `claim()` thành công, hệ thống tự động trừ **phí feeBps** cho owner.

---

## ⚙️ Các hàm chính

| Hàm | Vai trò | Ghi chú |
|-----|---------|---------|
| `deposit(token, amount, recipient, deadline, secretHash)` | Người gửi nạp tiền vào escrow | Hỗ trợ token ERC20 (cUSD, USDC, USDT...) |
| `claim(id, secret)` | Người nhận rút tiền bằng mã bí mật | Kiểm tra hash: `keccak256(abi.encodePacked(secret, recipient))` |
| `refund(id)` | Người gửi hoàn lại tiền sau hạn | Chỉ thực hiện được sau khi `deadline` qua |
| `setFeeBps(newFee)` | Chủ hợp đồng thay đổi tỷ lệ phí | `feeBps ≤ 10000` |
| `transferOwnership(newOwner)` | Chuyển quyền quản trị hợp đồng | Chỉ `owner` được phép gọi |

---
