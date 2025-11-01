// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SimpleEscrowAutoRelease is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public feeBps; // fee in basis points (0..10000)
    uint256 public nextId;

    struct Payment {
        address sender;
        address token;
        uint256 amountExpected;   // amount sender intended to deposit (approve amount)
        uint256 amountReceived;   // actual tokens received by contract (after transfer fees)
        address recipient;
        uint256 createdAt;
        uint256 unlockTimestamp;  // after this timestamp anyone can release
        bool released;
    }

    mapping(uint256 => Payment) public payments;

    event Deposited(
        uint256 indexed id,
        address indexed sender,
        address token,
        uint256 amountExpected,
        uint256 amountReceived,
        address indexed recipient,
        uint256 unlockTimestamp
    );

    event Released(uint256 indexed id, address indexed by, uint256 payout, address indexed recipient);
    event FeeChanged(uint256 oldFeeBps, uint256 newFeeBps);
    event OwnerWithdrawERC20(address indexed token, uint256 amount);
    event OwnerWithdrawNative(uint256 amount);

    /**
     * @dev Constructor sets initial fee and owner.
     * Note: Ownable(msg.sender) required for OpenZeppelin v5+ where Ownable constructor expects initial owner.
     */
    constructor(uint256 _feeBps) Ownable(msg.sender) {
        require(_feeBps <= 10000, "feeBps<=10000");
        feeBps = _feeBps;
        nextId = 1;
    }

    /**
     * @notice Deposit tokens into escrow.
     * @param token ERC20 token address (cannot be zero)
     * @param amountExpected amount in token smallest unit the sender expects to deposit (must approve this amount)
     * @param recipient recipient address
     * @param unlockTimestamp unix timestamp after which anyone may call release() if not released
     * @return id payment id
     *
     * Notes:
     * - We record actual received amount by checking balance before/after safeTransferFrom.
     * - unlockTimestamp must be at least `block.timestamp + 60` (1 minute) to avoid immediate release abuse.
     */
    function deposit(
        address token,
        uint256 amountExpected,
        address recipient,
        uint256 unlockTimestamp
    ) external returns (uint256) {
        require(token != address(0), "token zero");
        require(amountExpected > 0, "amount>0");
        require(recipient != address(0), "recipient zero");
        require(unlockTimestamp >= block.timestamp + 60, "unlockTimestamp too soon"); // at least 1 minute

        // get balance before
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // transfer from sender (SafeERC20 handles non-standard tokens)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountExpected);

        // get balance after to compute actual received
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "balance after < before");

        uint256 received = balanceAfter - balanceBefore;
        require(received > 0, "received zero");

        uint256 id = nextId;
        payments[id] = Payment({
            sender: msg.sender,
            token: token,
            amountExpected: amountExpected,
            amountReceived: received,
            recipient: recipient,
            createdAt: block.timestamp,
            unlockTimestamp: unlockTimestamp,
            released: false
        });

        nextId = id + 1;

        emit Deposited(id, msg.sender, token, amountExpected, received, recipient, unlockTimestamp);
        return id;
    }

    /**
     * @notice Release funds to recipient.
     * - Can be called by sender, recipient, owner anytime.
     * - After unlockTimestamp, anyone can call release() to avoid funds locked forever.
     */
    function release(uint256 id) external nonReentrant {
        Payment storage p = payments[id];
        require(p.amountReceived > 0, "not found or zero");
        require(!p.released, "already released");

        // authorization: sender/recipient/owner OR anyone after unlockTimestamp
        bool isAuthorized = (msg.sender == p.sender || msg.sender == p.recipient || msg.sender == owner());
        require(isAuthorized || block.timestamp >= p.unlockTimestamp, "not authorized");

        // Effects first
        p.released = true;

        // Fee calculation using amountReceived (safe against fee-on-transfer)
        uint256 fee = 0;
        if (feeBps > 0) {
            require(p.amountReceived == 0 || p.amountReceived <= type(uint256).max / feeBps, "fee calc overflow");
            fee = (p.amountReceived * feeBps) / 10000;
        }
        uint256 payout = p.amountReceived - fee;

        // Interactions: transfer payout and fee (if >0)
        IERC20(p.token).safeTransfer(p.recipient, payout);
        if (fee > 0) {
            IERC20(p.token).safeTransfer(owner(), fee);
        }

        emit Released(id, msg.sender, payout, p.recipient);
    }

    // Owner functions
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10000, "feeBps<=10000");
        emit FeeChanged(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function ownerWithdrawERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "token zero");
        IERC20(token).safeTransfer(owner(), amount);
        emit OwnerWithdrawERC20(token, amount);
    }

    function withdrawNative(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient native");
        payable(owner()).transfer(amount);
        emit OwnerWithdrawNative(amount);
    }

    // Accept native transfers
    receive() external payable {}
    fallback() external payable {}

    // View helper
    function getPayment(uint256 id) external view returns (Payment memory) {
        return payments[id];
    }
}
