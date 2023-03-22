// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import './IOracle.sol';
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "forge-std/console.sol";

contract DreamAcademyLending {
    // address usdcAddress;
    IPriceOracle _priceOracle;
    ERC20 _usdcERC20;

    uint _totalusdcAccumulated;
    uint _totalusdcAmount;
    uint _totalusdcLastUpdateTime;

    struct usdcHolder{
        uint _indivAccumulated;
        uint _indivAmount;
        uint _indivUpdateTime;
        uint _indivInterest;
    }

    mapping (address => usdcHolder) _usdcHolders;
    address [] _usdcHoldersAddr;

    uint _totalBorrowedAmount;
    uint _totalBorrowedAccumed;
    uint _totalBorrowedUpdateTime;

    struct etherHolder{
        uint _etherAmount;
        uint _borrowAmount;
        uint _borrowUpdateTime;
    }

    mapping (address => etherHolder) _etherHolders;

    uint constant LENDABLE_RATE1 = 1; // 분자
    uint constant LENDABLE_RATE2 = 2; // 분모
    uint constant LIQUIDATE_RATE1 = 3; // 분자
    uint constant LIQUIDATE_RATE2 = 4; // 분모
    uint constant INTEREST_RATE = 1000; // 분모
    uint constant INTERVAL = 24 hours;
    uint constant BLOCKTIME = 12;


    constructor(IPriceOracle _oracle, address _usdcAddr){
        _priceOracle = _oracle;
        _usdcERC20 = ERC20(_usdcAddr);
        _totalusdcLastUpdateTime = block.number * BLOCKTIME;
        _totalBorrowedUpdateTime = block.number * BLOCKTIME;
    }

    function initializeLendingProtocol(address usdcAddr_) public payable {
        _usdcERC20.transferFrom(msg.sender, address(this), msg.value);
        _totalusdcAmount += msg.value;
        _totalusdcLastUpdateTime = block.number * BLOCKTIME;
    }
    function deposit(address tokenAddress, uint256 amount) public payable {
        usdcCompound();
        indivBorrowedCompound(msg.sender);
        if(tokenAddress == address(0)){
            require(msg.value > 0, "no ether transfered");
            require(amount == msg.value, "different amount");
            _etherHolders[msg.sender]._etherAmount += msg.value;
        } else {
            require(amount > 0, "no usdc transfered");
            require(_usdcERC20.balanceOf(msg.sender) >= amount, "not enough usdc");
            uint256 accum = _usdcHolders[msg.sender]._indivAmount * (block.number * BLOCKTIME - _usdcHolders[msg.sender]._indivUpdateTime);
            _usdcHolders[msg.sender]._indivAccumulated += accum;
            _usdcHolders[msg.sender]._indivAmount += amount;
            _usdcHolders[msg.sender]._indivUpdateTime = block.number * BLOCKTIME;
            _totalusdcAmount += amount;
            bool flag = false;
            for(uint i=0; i<_usdcHoldersAddr.length; i++){
                if(_usdcHoldersAddr[i] == msg.sender) flag = true;
            }
            if(flag == false) {
                _usdcHoldersAddr.push(msg.sender);
            }
            rebalance();
            _usdcERC20.transferFrom(msg.sender, address(this), amount);
        }
    }
    function borrow(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        require(amount <= _usdcERC20.balanceOf(address(this)), "not enough usdc in vault");
        indivBorrowedCompound(msg.sender);
        uint256 rentable = _etherHolders[msg.sender]._etherAmount * _priceOracle.getPrice(address(0x0)) / _priceOracle.getPrice(tokenAddress) * LENDABLE_RATE1 / LENDABLE_RATE2 - _etherHolders[msg.sender]._borrowAmount;
        require(rentable >= amount, "not enough collateral");

        _etherHolders[msg.sender]._borrowAmount += amount;
        _etherHolders[msg.sender]._borrowUpdateTime = block.number * BLOCKTIME;
        _totalBorrowedAccumed += amount;
        _totalBorrowedAmount += amount;
        rebalance();
        _usdcERC20.transfer(msg.sender, amount);
    }
    function repay(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        indivBorrowedCompound(msg.sender);
        require(amount <= _usdcERC20.balanceOf(msg.sender), "less than you have");
        require(_etherHolders[msg.sender]._borrowAmount >= amount, "more than you borrowed");
        _etherHolders[msg.sender]._borrowAmount -= amount;
        rebalance();
        _usdcERC20.transferFrom(msg.sender, address(this), amount);
    }
    function liquidate(address user, address tokenAddress, uint256 amount) public {
        borrowedCompound();
        indivBorrowedCompound(user);
        require(amount <= _etherHolders[user]._borrowAmount, "not enough to liquidiate");
        require((_etherHolders[user]._etherAmount * _priceOracle.getPrice(address(0x0)) / _priceOracle.getPrice(tokenAddress)) * LIQUIDATE_RATE1 / LIQUIDATE_RATE2 < _etherHolders[user]._borrowAmount, "no liquidate needed");

        require(_etherHolders[user]._borrowAmount < 100 ether || amount == _etherHolders[user]._borrowAmount / 4, "only liquidating 25% possible");

        _etherHolders[user]._borrowAmount -= amount;
        _etherHolders[user]._etherAmount -= amount * _priceOracle.getPrice(tokenAddress) / _priceOracle.getPrice(address(0x0));
        _etherHolders[user]._borrowUpdateTime = block.number * BLOCKTIME;
        rebalance();
    }
    function withdraw(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        usdcCompound();
        if(tokenAddress == address(0)){
            indivBorrowedCompound(msg.sender);
            require(amount <= _etherHolders[msg.sender]._etherAmount, "more than owner's balance");
            require(amount <= address(this).balance, "more than this balance");
            
            require(_etherHolders[msg.sender]._borrowAmount * _priceOracle.getPrice(address(_usdcERC20)) / _priceOracle.getPrice(address(0x0)) <= (_etherHolders[msg.sender]._etherAmount - amount) * LIQUIDATE_RATE1 / LIQUIDATE_RATE2, "repay first");
            _etherHolders[msg.sender]._etherAmount -= amount;
            (bool success, ) = msg.sender.call{value: amount}(""); // call or send or transfer?
            require(success, "sending ether failed");
        } else {
            require(amount <= _usdcERC20.balanceOf(address(this)), "not enough balance on this contract");
            _usdcHolders[msg.sender]._indivAccumulated += _usdcHolders[msg.sender]._indivAmount * (block.number * BLOCKTIME - _usdcHolders[msg.sender]._indivUpdateTime);
            uint256 withdrawalAmount = getAccruedSupplyAmount(address(_usdcERC20));
            require(withdrawalAmount >= amount, "more than your balance");
            _totalusdcAccumulated -= _usdcHolders[msg.sender]._indivAccumulated * amount / withdrawalAmount;
            _totalusdcAmount -= amount;
            _usdcHolders[msg.sender]._indivAccumulated -= _usdcHolders[msg.sender]._indivAccumulated * amount / withdrawalAmount;
            _usdcHolders[msg.sender]._indivAmount -= _usdcHolders[msg.sender]._indivAmount * amount / withdrawalAmount;
            _usdcERC20.transfer(msg.sender, amount);
        }
    }

    function getAccruedSupplyAmount(address usdcAddr_) public returns (uint){
        rebalance();
        return _usdcHolders[msg.sender]._indivAmount + _usdcHolders[msg.sender]._indivInterest;
    }

    function usdcCompound() internal {
        _totalusdcAccumulated += _totalusdcAmount * (block.number * BLOCKTIME - _totalusdcLastUpdateTime);
        _totalusdcLastUpdateTime = block.number * BLOCKTIME;
    }

    // ds math library

    uint constant RAY = 10 ** 27;

    function add(uint x, uint y) internal view returns (uint z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }

    function mul(uint x, uint y) internal view returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }

    function rmul(uint x, uint y) public view returns (uint z) {
        z = add(mul(x, y), RAY / 2) / RAY;
    }

    function rpow(uint x, uint n) internal returns (uint z) {
        z = n % 2 != 0 ? x : RAY;

        for (n /= 2; n != 0; n /= 2) {
            x = rmul(x, x);

            if (n % 2 != 0) {
                z = rmul(z, x);
            }
        }
    }

    function accrueInterest(uint _principal, uint _rate, uint _age) internal returns (uint) {
        return rmul(_principal, rpow(_rate, _age));
    }

    function borrowedCompound() internal {
        uint timeInterval = block.number * BLOCKTIME - _totalBorrowedUpdateTime;
        _totalBorrowedAccumed = accrueInterest(_totalBorrowedAccumed, RAY+RAY/INTEREST_RATE, timeInterval / 24 hours);
        _totalBorrowedAccumed = accrueInterest(_totalBorrowedAccumed, 1000000011568290959081926677, timeInterval - (timeInterval / 24 hours) * 24 hours); // hard-coded the accurate interest
        _totalBorrowedUpdateTime = block.number * BLOCKTIME;
    }
    
    function indivBorrowedCompound(address user_) internal {
        uint timeInterval = block.number * BLOCKTIME - _etherHolders[user_]._borrowUpdateTime;
        _etherHolders[user_]._borrowAmount = accrueInterest(_etherHolders[user_]._borrowAmount, RAY+RAY/INTEREST_RATE, timeInterval / 24 hours);
        _etherHolders[user_]._borrowAmount = accrueInterest(_etherHolders[user_]._borrowAmount, 1000000011568290959081926677, timeInterval - (timeInterval / 24 hours) * 24 hours); // hard-coded the accurate interest
        _etherHolders[user_]._borrowUpdateTime = block.number * BLOCKTIME;
    }

    function rebalance() internal {
        usdcCompound();
        borrowedCompound();
        if(_totalusdcAccumulated == 0) return;
        for(uint i=0; i<_usdcHoldersAddr.length; i++){
            _usdcHolders[_usdcHoldersAddr[i]]._indivAccumulated += _usdcHolders[_usdcHoldersAddr[i]]._indivAmount * (block.number * BLOCKTIME - _usdcHolders[_usdcHoldersAddr[i]]._indivUpdateTime);
            _usdcHolders[_usdcHoldersAddr[i]]._indivInterest += (_totalBorrowedAccumed - _totalBorrowedAmount) * _usdcHolders[_usdcHoldersAddr[i]]._indivAccumulated / _totalusdcAccumulated;
            _usdcHolders[_usdcHoldersAddr[i]]._indivUpdateTime = block.number * BLOCKTIME;
            _usdcHolders[_usdcHoldersAddr[i]]._indivAccumulated = 0;
        }
        _totalBorrowedAmount = _totalBorrowedAccumed;
        _totalusdcAccumulated = 0;
    }
}