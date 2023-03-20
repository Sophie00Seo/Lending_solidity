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
    }

    mapping (address => usdcHolder) _usdcHolders;

    uint _totalBorrowedAmount;
    uint _totalBorrowedAcummulated;
    uint _totalBorrowedUpdateTime;

    struct etherHolder{
        uint _etherAmount;
        uint _borrowAmount;
        uint _borrowUpdateTime;
    }

    mapping (address => etherHolder) _etherHolders;

    constructor(IPriceOracle _oracle, address _usdcAddr){
        _priceOracle = _oracle;
        _usdcERC20 = ERC20(_usdcAddr);
        _totalusdcLastUpdateTime = block.number;
        _totalBorrowedUpdateTime = block.number;
    }

    function initializeLendingProtocol(address usdcAddr_) public payable {
        _usdcERC20.transferFrom(msg.sender, address(this), msg.value);
        _totalusdcAmount += msg.value;
        _totalusdcLastUpdateTime = block.number;
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
            uint256 accum = _usdcHolders[msg.sender]._indivAmount * (block.number - _usdcHolders[msg.sender]._indivUpdateTime);
            _usdcHolders[msg.sender]._indivAccumulated += accum;
            _usdcHolders[msg.sender]._indivAmount += amount;
            _usdcHolders[msg.sender]._indivUpdateTime = block.number;
            _totalusdcAmount += amount;
            _usdcERC20.transferFrom(msg.sender, address(this), amount);
        }
    }
    function borrow(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        require(amount <= _usdcERC20.balanceOf(address(this)), "not enough usdc in vault");
        indivBorrowedCompound(msg.sender);
        uint256 rentable = _etherHolders[msg.sender]._etherAmount * _priceOracle.getPrice(address(0x0)) / _priceOracle.getPrice(tokenAddress) / 2 - _etherHolders[msg.sender]._borrowAmount;
        require(rentable >= amount, "not enough collateral");

        _etherHolders[msg.sender]._borrowAmount += amount;
        _etherHolders[msg.sender]._borrowUpdateTime = block.number;
        _totalBorrowedAcummulated += amount;
        _totalBorrowedAmount += amount;
        _usdcERC20.transfer(msg.sender, amount);
    }
    function repay(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        indivBorrowedCompound(msg.sender);
        require(amount <= _usdcERC20.balanceOf(msg.sender), "less than you have");
        require(_etherHolders[msg.sender]._borrowAmount >= amount, "more than you borrowed");
        _etherHolders[msg.sender]._borrowAmount -= amount;
        _usdcERC20.transferFrom(msg.sender, address(this), amount);
    }
    function liquidate(address user, address tokenAddress, uint256 amount) public {
        borrowedCompound();
        indivBorrowedCompound(user);
        require(amount <= _etherHolders[user]._borrowAmount, "not enough to liquidiate");
        require((_etherHolders[user]._etherAmount * _priceOracle.getPrice(address(0x0)) / _priceOracle.getPrice(tokenAddress)) * 3 / 4 < _etherHolders[user]._borrowAmount, "no liquidate needed");

        require(_etherHolders[user]._borrowAmount < 100 ether || amount == _etherHolders[user]._borrowAmount / 4, "only liquidating 25% possible");

        _etherHolders[user]._borrowAmount -= amount;
        _etherHolders[user]._etherAmount -= amount * _priceOracle.getPrice(tokenAddress) / _priceOracle.getPrice(address(0x0));
        _etherHolders[user]._borrowUpdateTime = block.number;
    }
    function withdraw(address tokenAddress, uint256 amount) public {
        borrowedCompound();
        usdcCompound();
        if(tokenAddress == address(0)){
            indivBorrowedCompound(msg.sender);
            require(amount <= _etherHolders[msg.sender]._etherAmount, "more than owner's balance");
            require(amount <= address(this).balance, "more than this balance");
            
            require(_etherHolders[msg.sender]._borrowAmount * _priceOracle.getPrice(address(_usdcERC20)) / _priceOracle.getPrice(address(0x0)) <= (_etherHolders[msg.sender]._etherAmount - amount) * 3 / 4, "repay first");
            _etherHolders[msg.sender]._etherAmount -= amount;
            (bool success, ) = msg.sender.call{value: amount}(""); // call or send or transfer?
            require(success, "sending ether failed");
        } else {
            require(amount <= _usdcERC20.balanceOf(address(this)), "not enough balance on this contract");
            require(amount <= _usdcHolders[msg.sender]._indivAmount, "more than your balance");
            _usdcHolders[msg.sender]._indivAccumulated += _usdcHolders[msg.sender]._indivAmount * (block.number - _usdcHolders[msg.sender]._indivUpdateTime);
            uint256 withdrawalAmount = getAccruedSupplyAmount(address(_usdcERC20));
            _totalusdcAccumulated -= _usdcHolders[msg.sender]._indivAccumulated;
            _totalusdcAmount -= withdrawalAmount;
            _usdcERC20.transfer(msg.sender, withdrawalAmount);
        }
    }

    function getAccruedSupplyAmount(address usdcAddr_) public returns (uint){
        usdcCompound();
        borrowedCompound();
        uint256 accum = _usdcHolders[msg.sender]._indivAmount * (block.number - _usdcHolders[msg.sender]._indivUpdateTime);
        _usdcHolders[msg.sender]._indivAccumulated += accum;
        _usdcHolders[msg.sender]._indivUpdateTime = block.number;
        return _usdcHolders[msg.sender]._indivAmount + (_totalBorrowedAcummulated - _totalBorrowedAmount) * _usdcHolders[msg.sender]._indivAccumulated / _totalusdcAccumulated;
    }

    function usdcCompound() internal {
        _totalusdcAccumulated += _totalusdcAmount * (block.number - _totalusdcLastUpdateTime);
        _totalusdcLastUpdateTime = block.number;
    }

    uint constant RAY = 10 ** 27;

    function add(uint x, uint y) internal view returns (uint z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }

    function mul(uint x, uint y) internal view returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }

    function div(uint x, uint y) public view returns (uint){
        return x / y;
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
        uint timeInterval = block.number - _totalBorrowedUpdateTime;
        _totalBorrowedAcummulated = accrueInterest(_totalBorrowedAcummulated, RAY + RAY / 1000 / 24 hours, timeInterval);
        
        _totalBorrowedUpdateTime = block.number;                                                                                                                                                                                                      
    }
    
    function indivBorrowedCompound(address user_) internal {
        uint timeInterval = block.number - _etherHolders[user_]._borrowUpdateTime;
        _etherHolders[user_]._borrowAmount = accrueInterest(_etherHolders[user_]._borrowAmount, RAY + RAY / 1000 / 24 hours, timeInterval);
        
        _etherHolders[user_]._borrowUpdateTime = block.number;
    }
}