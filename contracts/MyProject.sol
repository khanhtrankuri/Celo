// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
 RemittanceEscrowSecret.sol

 - Tính năng chính:
   * Escrow theo lô (id tự tăng)
   * Người gửi nạp (deposit) stablecoin (ví dụ cUSD/USDC trên Celo)
   * Người nhận rút bằng cách cung cấp secret hợp lệ trước deadline
   * Quá hạn => chỉ người gửi được refund
   * Phí linh hoạt feeBps (0..10000), thu khi claim thành công
   * SafeERC20 tối giản + chống reentrancy
   * Hỗ trợ fee-on-transfer (ghi nhận amountExpected/amountReceived qua chênh lệch balance)
 - Lưu ý bảo mật:
   * secretHash = keccak256(abi.encodePacked(secret, recipient)) (khuyến nghị) tính OFF-CHAIN
   * Contract KHÔNG có hàm ownerWithdraw ERC20 để tránh rủi ro "rug"
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
        if (returndata.length > 0) {
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

contract RemittanceEscrowSecret is SimpleOwnable, SimpleReentrancyGuard {
    using SafeERC20 for address; // gọi SafeERC20 qua kiểu address

    uint256 public feeBps; // 0..10000
    uint256 public nextId;

    struct Payment {
        address sender;         // người gửi (depositor)
        address token;          // ERC20 stablecoin (cUSD/USDC...)
        uint256 amountExpected; // số lượng mong muốn chuyểnFrom
        uint256 amountReceived; // số lượng thực đã vào escrow (hỗ trợ fee-on-transfer)
        address recipient;      // người nhận
        uint256 createdAt;      // thời điểm nạp
        uint256 deadline;       // hạn cuối để người nhận claim bằng secret
        bytes32 secretHash;     // keccak256(abi.encodePacked(secret, recipient)) (khuyến nghị)
        bool claimed;           // đã claim thành công?
        bool refunded;          // đã refund cho sender?
    }

    mapping(uint256 => Payment) public payments;

    event Deposited(
        uint256 indexed id,
        address indexed sender,
        address token,
        uint256 amountExpected,
        uint256 amountReceived,
        address indexed recipient,
        uint256 deadline,
        bytes32 secretHash
    );

    event Claimed(
        uint256 indexed id,
        address indexed recipient,
        uint256 payout,     // số tiền thực nhận sau khi trừ phí
        uint256 feeToOwner  // phí chuyển cho owner
    );

    event Refunded(
        uint256 indexed id,
        address indexed sender,
        uint256 amount
    );

    event FeeChanged(uint256 oldFeeBps, uint256 newFeeBps);

    event OwnerWithdrawNative(uint256 amount);

    constructor(uint256 _feeBps) {
        require(_feeBps <= 10000, "feeBps<=10000");
        feeBps = _feeBps;
        nextId = 1;
    }

    /**
     * @notice Nạp tiền vào escrow.
     * @param token địa chỉ ERC20 stablecoin (ví dụ cUSD)
     * @param amountExpected số lượng dự định chuyểnFrom
     * @param recipient người nhận
     * @param deadline hạn cuối claim (>= block.timestamp + 60)
     * @param secretHash hash bí mật: khuyến nghị = keccak256(abi.encodePacked(secret, recipient))
     * @return id mã thanh toán
     */
    function deposit(
        address token,
        uint256 amountExpected,
        address recipient,
        uint256 deadline,
        bytes32 secretHash
    ) external returns (uint256 id) {
        require(token != address(0), "token zero");
        require(amountExpected > 0, "amount>0");
        require(recipient != address(0), "recipient zero");
        require(secretHash != bytes32(0), "secretHash zero");
        require(deadline >= block.timestamp + 60, "deadline too soon");

        // số dư trước
        uint256 balBefore = IERC20(token).balanceOf(address(this));

        // chuyển token vào escrow (an toàn)
        SafeERC20.safeTransferFrom(token, msg.sender, address(this), amountExpected);

        // số dư sau
        uint256 balAfter = IERC20(token).balanceOf(address(this));
        require(balAfter >= balBefore, "balance after < before");

        uint256 received = balAfter - balBefore;
        require(received > 0, "received zero");

        id = nextId;
        payments[id] = Payment({
            sender: msg.sender,
            token: token,
            amountExpected: amountExpected,
            amountReceived: received,
            recipient: recipient,
            createdAt: block.timestamp,
            deadline: deadline,
            secretHash: secretHash,
            claimed: false,
            refunded: false
        });

        nextId = id + 1;

        emit Deposited(id, msg.sender, token, amountExpected, received, recipient, deadline, secretHash);
    }

    /**
     * @notice Người nhận rút tiền bằng secret trước deadline.
     * @param id mã thanh toán
     * @param secret bytes bất kỳ; hợp lệ khi keccak256(abi.encodePacked(secret, recipient)) == secretHash
     */
    function claim(uint256 id, string calldata secret) external nonReentrant {
        Payment storage p = payments[id];
        require(p.amountReceived > 0, "not found or zero");
        require(!p.claimed, "already claimed");
        require(!p.refunded, "already refunded");
        require(block.timestamp <= p.deadline, "past deadline");
        require(msg.sender == p.recipient, "not recipient");

        // hash bí mật theo chuỗi string
        bytes32 h = keccak256(abi.encodePacked(bytes(secret), p.recipient));
        require(h == p.secretHash, "invalid secret");

        p.claimed = true;

        uint256 fee = (p.amountReceived * feeBps) / 10000;
        uint256 payout = p.amountReceived - fee;

        SafeERC20.safeTransfer(p.token, p.recipient, payout);
        if (fee > 0) SafeERC20.safeTransfer(p.token, owner(), fee);

        emit Claimed(id, p.recipient, payout, fee);
    }



    /**
     * @notice Quá hạn, người gửi được refund.
     * @param id mã thanh toán
     */
    function refund(uint256 id) external nonReentrant {
        Payment storage p = payments[id];
        require(p.amountReceived > 0, "not found or zero");
        require(!p.claimed, "already claimed");
        require(!p.refunded, "already refunded");
        require(block.timestamp > p.deadline, "not expired");
        require(msg.sender == p.sender, "not sender");

        p.refunded = true;

        // Hoàn lại toàn bộ amountReceived cho người gửi
        SafeERC20.safeTransfer(p.token, p.sender, p.amountReceived);

        emit Refunded(id, p.sender, p.amountReceived);
    }

    // ============ Owner functions ============

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10000, "feeBps<=10000");
        emit FeeChanged(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    // Chỉ rút native (nếu ai đó gửi nhầm)
    function withdrawNative(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "insufficient native");
        payable(owner()).transfer(amount);
        emit OwnerWithdrawNative(amount);
    }

    receive() external payable {}
    fallback() external payable {}

    // Helper
    function getPayment(uint256 id) external view returns (Payment memory) {
        return payments[id];
    }
}
