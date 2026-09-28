// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ApexEmpire {
    // =============================================================
    // TOKEN
    // =============================================================

    string public constant name = "APEX EMPIRE";
    string public constant symbol = "APXE";
    uint8 public constant decimals = 18;

    uint256 private constant INITIAL_SUPPLY = 71_000_000 * 10 ** 18;
    uint256 public constant MIN_SUPPLY = 40_000_000 * 10 ** 18;
    uint256 public constant BUY_TAX = 5;
    uint256 public constant SELL_TAX = 5;
    uint256 public constant BURN_TAX = 2;

    /// @dev Fixed owner + tax + supply receiver
    address public constant TREASURY =
        0x90611725A626eE6469055F06AA16C31ad7Eac153;

    uint256 private _totalSupply = INITIAL_SUPPLY;

    // =============================================================
    // OWNER / TAX
    // =============================================================

    address public owner;
    address public taxWallet;

    // =============================================================
    // DEX / TRADING
    // =============================================================

    address public dexPair;

    bool public paused;
    bool public tradingEnabled = false;
    uint256 public launchTime;

    // =============================================================
    // ANTI-BOT / BLACKLIST
    // =============================================================

    bool public antiBotEnabled = true;
    uint256 public antiBotDuration = 60;

    mapping(address => uint256) public firstTransferBlock;
    mapping(address => bool) public isBlacklisted;

    // =============================================================
    // BALANCES / ALLOWANCES
    // =============================================================

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // =============================================================
    // REENTRANCY
    // =============================================================

    uint256 private _locked = 1;

    // =============================================================
    // EVENTS
    // =============================================================

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TaxWalletUpdated(address indexed wallet);
    event DEXPairUpdated(address indexed previousPair, address indexed newPair);
    event TradingStarted(uint256 timestamp);
    event TokensBurned(address indexed from, uint256 amount);
    event EmergencyPause(bool status);
    event BlacklistUpdated(address indexed account, bool status);
    event AntiBotUpdated(bool enabled, uint256 duration);

    // =============================================================
    // MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "APXE: not owner");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "APXE: reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "APXE: token paused");
        _;
    }

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    constructor() {
        owner = TREASURY;
        taxWallet = TREASURY;
        _balances[TREASURY] = INITIAL_SUPPLY;

        emit Transfer(address(0), TREASURY, INITIAL_SUPPLY);
        emit OwnershipTransferred(address(0), TREASURY);
        emit TaxWalletUpdated(TREASURY);
    }

    // =============================================================
    // ERC20 / BEP20
    // =============================================================

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address tokenOwner, address spender) external view returns (uint256) {
        return _allowances[tokenOwner][spender];
    }

    function transfer(address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount)
        external
        whenNotPaused
        returns (bool)
    {
        require(spender != address(0), "APXE: zero spender");

        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "APXE: insufficient allowance");

        unchecked {
            _allowances[from][msg.sender] = currentAllowance - amount;
        }

        emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        external
        whenNotPaused
        returns (bool)
    {
        require(spender != address(0), "APXE: zero spender");

        _allowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        whenNotPaused
        returns (bool)
    {
        require(spender != address(0), "APXE: zero spender");

        uint256 currentAllowance = _allowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "APXE: decreased allowance below zero");

        unchecked {
            _allowances[msg.sender][spender] = currentAllowance - subtractedValue;
        }

        emit Approval(msg.sender, spender, _allowances[msg.sender][spender]);
        return true;
    }

    // =============================================================
    // INTERNAL TRANSFER
    // =============================================================

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "APXE: zero sender");
        require(to != address(0), "APXE: zero receiver");
        require(!isBlacklisted[from] && !isBlacklisted[to], "APXE: blacklisted");
        require(_balances[from] >= amount, "APXE: insufficient balance");

        if (!tradingEnabled) {
            require(from == owner || to == owner, "APXE: trading not started");
        }

        if (
            tradingEnabled &&
            antiBotEnabled &&
            block.timestamp < launchTime + antiBotDuration
        ) {
            if (from == dexPair && to != owner) {
                if (firstTransferBlock[to] == 0) {
                    firstTransferBlock[to] = block.number;
                }
            }

            if (to == dexPair && from != owner) {
                require(
                    firstTransferBlock[from] == 0 ||
                    firstTransferBlock[from] < block.number,
                    "APXE: sniper sell blocked"
                );
            }
        }

        uint256 taxAmount = 0;
        uint256 burnAmount = 0;

        if (
            from != owner &&
            to != owner &&
            from != taxWallet &&
            to != taxWallet &&
            dexPair != address(0)
        ) {
            if (from == dexPair) {
                taxAmount = (amount * BUY_TAX) / 100;
            } else if (to == dexPair) {
                taxAmount = (amount * SELL_TAX) / 100;
            }

            if (_totalSupply > MIN_SUPPLY) {
                uint256 possibleBurn = (amount * BURN_TAX) / 100;
                uint256 availableBurn = _totalSupply - MIN_SUPPLY;
                burnAmount = possibleBurn > availableBurn ? availableBurn : possibleBurn;
            }
        }

        uint256 totalDeduction = taxAmount + burnAmount;
        require(amount >= totalDeduction, "APXE: invalid tax");

        uint256 receiveAmount = amount - totalDeduction;

        unchecked {
            _balances[from] -= amount;
        }

        if (taxAmount > 0) {
            _balances[taxWallet] += taxAmount;
            emit Transfer(from, taxWallet, taxAmount);
        }

        if (burnAmount > 0) {
            _totalSupply -= burnAmount;
            emit Transfer(from, address(0), burnAmount);
            emit TokensBurned(from, burnAmount);
        }

        if (receiveAmount > 0) {
            _balances[to] += receiveAmount;
            emit Transfer(from, to, receiveAmount);
        }
    }

    // =============================================================
    // ADMIN
    // =============================================================

    function setTaxWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "APXE: zero wallet");
        taxWallet = newWallet;
        emit TaxWalletUpdated(newWallet);
    }

    function setDEXPair(address newPair) external onlyOwner {
        require(newPair != address(0), "APXE: zero DEX pair");
        require(!tradingEnabled, "APXE: cannot change pair after trading started");

        address oldPair = dexPair;
        dexPair = newPair;

        emit DEXPairUpdated(oldPair, newPair);
    }

    function startTrading() external onlyOwner {
        require(!tradingEnabled, "APXE: trading already started");
        require(dexPair != address(0), "APXE: DEX pair not set");

        tradingEnabled = true;
        launchTime = block.timestamp;

        emit TradingStarted(launchTime);
    }

    function setAntiBot(bool enabled, uint256 duration) external onlyOwner {
        require(duration <= 3600, "APXE: max duration is 1 hour");

        antiBotEnabled = enabled;
        antiBotDuration = duration;

        emit AntiBotUpdated(enabled, duration);
    }

    function setBlacklist(address account, bool status) external onlyOwner {
        require(account != owner, "APXE: cannot blacklist owner");
        require(account != dexPair, "APXE: cannot blacklist DEX pair");
        require(account != taxWallet, "APXE: cannot blacklist tax wallet");

        isBlacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function setPause(bool status) external onlyOwner {
        paused = status;
        emit EmergencyPause(status);
    }

    function recoverERC20(address token, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token != address(this), "APXE: cannot recover APXE");
        require(token != address(0), "APXE: invalid token");

        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", owner, amount)
        );

        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "APXE: recovery failed"
        );
    }

    function recoverBNB() external onlyOwner nonReentrant {
        (bool success,) = payable(owner).call{value: address(this).balance}("");
        require(success, "APXE: BNB recovery failed");
    }

    receive() external payable {}

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "APXE: zero owner");

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // =============================================================
    // VIEWS
    // =============================================================

    function burnStatus()
        external
        view
        returns (uint256 currentSupply, uint256 minimumSupply, bool burnActive)
    {
        currentSupply = _totalSupply;
        minimumSupply = MIN_SUPPLY;
        burnActive = _totalSupply > MIN_SUPPLY;
    }

    function burnRemainingUntilFloor() external view returns (uint256) {
        if (_totalSupply <= MIN_SUPPLY) {
            return 0;
        }
        return _totalSupply - MIN_SUPPLY;
    }
}
