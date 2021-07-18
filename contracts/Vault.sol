// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface StakingPool {
    function deposit(uint256 poolId, uint256 _depositAmount) external;
    function withdraw(uint256 poolId, uint256 _withdrawAmount) external;
    function claim(uint256 poolId) external;
    function exit(uint256 poolId) external;
    function getStakeTotalUnclaimed(address _account, uint256 poolId) external view returns (uint256);
    function getStakeTotalDeposited(address _account, uint256 poolId) external view returns (uint256);
}

// Simple vault for autocompounding ALCX rewards from single-stake ALCX pool 
contract AlcxVault is ERC20 {

    // built in overflow checks from solidity 0.8
    using SafeERC20 for IERC20;

    event Harvest(address indexed harvester, uint256 fee); 

    event ChangedStrategistFee(uint256 fee);
    event ChangedHarvestFee(uint256 fee);

    address public strategist; 
    uint256 public strategistFee;

    // Amount paid to harvester for helping to restake/harvest
    uint256 public harvestFee; 
    uint256 constant MAX_BPS = 10000;
    uint256 constant MAX_STRATEGIST_FEE = 200;    
    uint256 constant MAX_HARVEST_FEE = 100;
    uint256 constant MAX_INT = 2 ** 256 - 1;

    // POOL_ID for ALCX single stake pool in the staking pool contract
    uint256 constant POOL_ID = 1; 

    address constant ALCX_STAKING_POOL_ADDRESS = 0xAB8e74017a8Cc7c15FFcCd726603790d26d7DeCa;
    StakingPool private alcxStakingPool = StakingPool(ALCX_STAKING_POOL_ADDRESS);    
    address constant ALCX_ADDRESS = 0xdBdb4d16EdA451D0503b854CF79D55697F90c8DF;
    IERC20 private alcx = IERC20(ALCX_ADDRESS);


    modifier onlyStrategist {
        require(msg.sender == strategist);
        _;
    }

    constructor(address _strategist) ERC20("Nuggies AlcxVault", "nALCX") {
        harvestFee = MAX_HARVEST_FEE; 
        strategistFee = MAX_STRATEGIST_FEE;
        strategist = _strategist;     

        // enable infinite approval from vault to staking pools 
        alcx.approve(ALCX_STAKING_POOL_ADDRESS, MAX_INT); 
    }

    function setStrategistFee(uint256 _strategistFee) external onlyStrategist {
        require(_strategistFee <= MAX_STRATEGIST_FEE, "exceeds maximum fee"); 
        strategistFee = _strategistFee;
        emit ChangedStrategistFee(_strategistFee);
    }

    function setHarvestFee(uint256 _harvestFee) external onlyStrategist {
        require(_harvestFee <= MAX_HARVEST_FEE, "exceeds maximum fee");
        harvestFee = _harvestFee;
        emit ChangedHarvestFee(_harvestFee);
    }

    // Computes the total amount of ALCX tokens 
    function totalAssets() external view returns (uint256 assets) {
        assets = 
            alcxStakingPool.getStakeTotalDeposited(address(this), POOL_ID) + 
            alcxStakingPool.getStakeTotalUnclaimed(address(this), POOL_ID);
    }

    // Total amount of ALCX tokens deposited into the single stake ALCX pool
    function totalStakedAssets() external view returns (uint256 assets) {
        assets = alcxStakingPool.getStakeTotalDeposited(address(this), POOL_ID);
    }

    // Total pending rewards for the ALCX pool
    function totalPendingRewards() external view returns (uint256 rewards) {
        rewards = alcxStakingPool.getStakeTotalUnclaimed(address(this), POOL_ID);
    }

    // Computes the amount of ALCX tokens that would be awarded for calling harvest()
    function totalPendingHarvestFees() external view returns (uint256 pendingHarvestFees) {
        pendingHarvestFees = alcxStakingPool.getStakeTotalUnclaimed(address(this), POOL_ID) * harvestFee / MAX_BPS; 
    }

    // Computes the amount of ALCX tokens that a user can redeem their shares for  
    // Discounted by fees 
    function totalStakedAssets(address _user) external view returns(uint256 netAlcxAmount) {
        uint256 assets = _totalDiscountedAssets();
        
        if (totalSupply() == 0) {
            netAlcxAmount = 0;
        } else {
            netAlcxAmount = balanceOf(_user) * assets / totalSupply();
        }
    }

    // Computes the total amount of ALCX tokens factoring in the fees on pending rewards
    function _totalDiscountedAssets() internal view returns (uint256 assets) {
        uint256 unclaimedRewards = alcxStakingPool.getStakeTotalUnclaimed(address(this), POOL_ID);
        uint256 discountedRewards = unclaimedRewards - (strategistFee + harvestFee) * unclaimedRewards / MAX_BPS;
        assets = alcxStakingPool.getStakeTotalDeposited(address(this), POOL_ID) + discountedRewards;
    }

    // Deposit ALCX tokens into the vault in exchange for vault shares (nALCX tokens)
    function deposit(uint256 _alcxAmount) external returns (uint256 shares) {
        require(_alcxAmount > 0, "must deposit nonzero amount");

        if (totalSupply() == 0) {
            shares = _alcxAmount;
        } else {
            // _alcxAmount / _totalDiscountedAssets = shares / totalSupply 
            shares = _alcxAmount * totalSupply() / _totalDiscountedAssets();
        }
        
        _mint(msg.sender, shares);

        alcx.safeTransferFrom(msg.sender, address(this), _alcxAmount);
        alcxStakingPool.deposit(POOL_ID, _alcxAmount); 
    }
 
    // Burn nALCX tokens (vault shares) in exchange for ALCX tokens
    // Note: withdrawer also receives harvest fees 
    function withdraw(uint _amountShares) external returns (uint256 withdrawnAmount) {
        require(_amountShares > 0, "must withdraw nonzero amount");
        (uint256 strategistFeeAmount, uint256 harvestFeeAmount) = _exitFees();

        alcxStakingPool.exit(POOL_ID);

        // _amountShares / totalSupply = withdrawnAmount / totalWithdrawnAmount
        // Note: harvest fees go to withdrawer and totalWithdrawnAmount must discount fees
        withdrawnAmount = _amountShares * (alcx.balanceOf(address(this)) - harvestFeeAmount - strategistFeeAmount) / totalSupply()
            + harvestFeeAmount;

        _burn(msg.sender, _amountShares);

        alcx.safeTransfer(strategist, strategistFeeAmount); 
        alcx.safeTransfer(msg.sender, withdrawnAmount);

        alcxStakingPool.deposit(POOL_ID, alcx.balanceOf(address(this)));
    }

    // Compounds the current pending ALCX rewards back into the staking pool
    function harvest() external returns (uint256 harvestFeeAmount) {
        uint256 strategistFeeAmount;
        (strategistFeeAmount, harvestFeeAmount) = _exitFees();

        alcxStakingPool.claim(POOL_ID);

        alcx.safeTransfer(strategist, strategistFeeAmount); 
        alcx.safeTransfer(msg.sender, harvestFeeAmount);

        alcxStakingPool.deposit(POOL_ID, alcx.balanceOf(address(this)));

        emit Harvest(msg.sender, harvestFeeAmount);
    }

    // calculate fees for strategist and harvester when exiting from staking pool 
    function _exitFees() internal view returns (uint256 strategistFeeAmount, uint256 harvestFeeAmount) {
        uint256 rewardAmount = alcxStakingPool.getStakeTotalUnclaimed(address(this), POOL_ID);  
        strategistFeeAmount = rewardAmount * strategistFee / MAX_BPS;
        harvestFeeAmount = rewardAmount * harvestFee / MAX_BPS;
    }

    // Withdraw random tokens that were accidently sent to contract
    // Note: ALCX tokens should never be in the contract itself 
    // Each of the operations deposit, withdraw, and harvest preserve the invariant: 
    //      alcx.balanceOf(address(this)) == 0 
    function clearTokens(address token) external onlyStrategist {
        uint balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(strategist, balance);
    }
}

