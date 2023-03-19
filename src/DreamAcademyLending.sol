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
        indivBorrowedCompound(msg.sender);
        if(tokenAddress == address(0)){
            require(amount <= _etherHolders[msg.sender]._etherAmount, "more than owner's balance");
            require(_etherHolders[msg.sender]._borrowAmount * _priceOracle.getPrice(address(_usdcERC20)) / _priceOracle.getPrice(address(0x0))  <= (_etherHolders[msg.sender]._etherAmount - amount) * 3 / 4, "repay first");
            require(amount <= address(this).balance, "more than this balance");
            (bool success, ) = msg.sender.call{value: amount}(""); // call or send or transfer?
            require(success, "sending ether failed");
        } else {

        }
    }

    function getAccruedSupplyAmount(address usdcAddr_) public returns (uint){
        
    }

    function usdcCompound() internal {
        _totalusdcAccumulated += _totalusdcAmount * (block.number - _totalusdcLastUpdateTime);
        _totalusdcLastUpdateTime = block.number;
    }

    function borrowedCompound() internal {
        uint timeInterval = block.number - _totalBorrowedUpdateTime;
        if(timeInterval < 24 hours) {
            _totalBorrowedAcummulated = _totalBorrowedAcummulated * (1 + 1000 * 24 hours) ** timeInterval / (1000 * 24 hours) ** timeInterval;
        } else {
            _totalBorrowedAcummulated = _totalBorrowedAcummulated * 1001 ** (timeInterval / 24 hours) / 1000 ** (timeInterval / 24 hours);
        }
        _totalBorrowedUpdateTime = block.number;
    }
    
    function indivBorrowedCompound(address user_) internal {
        uint timeInterval = block.number - _etherHolders[user_]._borrowUpdateTime;
        _etherHolders[user_]._borrowAmount = _etherHolders[user_]._borrowAmount * (1 + 1000 * 24 hours) ** timeInterval / (1000 * 24 hours) ** timeInterval;
        _etherHolders[user_]._borrowUpdateTime = block.number;
    }
}
