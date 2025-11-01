// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
  SimpleEscrowAutoReleaseStandalone.sol

  - Self-contained (no external OpenZeppelin imports) for easy Remix + Injected Provider (MetaMask) use.
  - Features:
    * Simple Ownable
    * ReentrancyGuard (nonReentrant)
    * SafeERC20 minimal (safeTransfer/safeTransferFrom using low-level call and return-data checks)
    * Records amountExpected and amountReceived (supports fee-on-transfer tokens)
    * unlockTimestamp per deposit, anyone can release after unlockTimestamp
    * Fee in basis points (feeBps). Owner receives fee on release.
*/

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @notice minimal SafeERC20 (handles tokens that do not return bool)
library SafeERC20 {
    function _callOptionalReturn(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        require(success, "ERC20: low-level call failed");

        if (returndata.length > 0) { // Return data is optional
            // Tokens that return a bool will return 32 bytes; decode and require true
            require(abi.decode(returndata, (bool)), "ERC20: operation did not succeed");
        }
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.transfer.selector, to, value));
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
    }

    function safeApprove(address token, address spender, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20.approve.selector, spender, value));
    }
}

/// @notice Simple ownable
contract SimpleOwnable {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "only owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

/// @notice Simple reentrancy guard
contract SimpleReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; } // 1 = not entered, 2 = entered

    modifier nonReentrant() {
        require(_status == 1, "reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

contract SimpleEscrowAutoRelease is SimpleOwnable, SimpleReentrancyGuard {
    using SafeERC20 for address; // call SafeERC20 functions via address type

    uint256 public feeBps; // 0..10000
    uint256 public nextId;

    struct Payment {
        address sender;
        address token;
        uint256 amountExpected;
        uint256 amountReceived;
        address recipient;
        uint256 createdAt;
        uint256 unlockTimestamp;
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

    constructor(uint256 _feeBps) {
        require(_feeBps <= 10000, "feeBps<=10000");
        feeBps = _feeBps;
        nextId = 1;
    }

    function deposit(
        address token,
        uint256 amountExpected,
        address recipient,
        uint256 unlockTimestamp
    ) external returns (uint256) {
        require(token != address(0), "token zero");
        require(amountExpected > 0, "amount>0");
        require(recipient != address(0), "recipient zero");
        require(unlockTimestamp >= block.timestamp + 60, "unlockTimestamp too soon");

        // balance before
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // transferFrom (safe)
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), amountExpected);

        // balance after
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

    function release(uint256 id) external nonReentrant {
        Payment storage p = payments[id];
        require(p.amountReceived > 0, "not found or zero");
        require(!p.released, "already released");

        bool isAuthorized = (msg.sender == p.sender || msg.sender == p.recipient || msg.sender == owner());
        require(isAuthorized || block.timestamp >= p.unlockTimestamp, "not authorized");

        // effects
        p.released = true;

        uint256 fee = 0;
        if (feeBps > 0) {
            require(p.amountReceived == 0 || p.amountReceived <= type(uint256).max / feeBps, "fee calc overflow");
            fee = (p.amountReceived * feeBps) / 10000;
        }
        uint256 payout = p.amountReceived - fee;

        // interactions
        SafeERC20.safeTransfer(p.token, p.recipient, payout);
        if (fee > 0) {
            SafeERC20.safeTransfer(p.token, owner(), fee);
        }

        emit Released(id, msg.sender, payout, p.recipient);
    }

    // owner functions
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10000, "feeBps<=10000");
        emit FeeChanged(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function ownerWithdrawERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "token zero");
        SafeERC20.safeTransfer(token, owner(), amount);
        emit OwnerWithdrawERC20(token, amount);
    }

    function withdrawNative(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient native");
        payable(owner()).transfer(amount);
        emit OwnerWithdrawNative(amount);
    }

    receive() external payable {}
    fallback() external payable {}

    function getPayment(uint256 id) external view returns (Payment memory) {
        return payments[id];
    }
}
