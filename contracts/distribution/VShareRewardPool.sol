// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IRewardPool.sol";

// Note that this pool has no minter key of VShare (rewards).
// Instead, the governance will call VShare distributeReward method and send reward to this pool at the beginning.
contract VShareRewardPool is IRewardPool, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;
    address public treasury;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. VShares to distribute per block.
        uint256 lastRewardTime; // Last time that VShares distribution occurs.
        uint256 accVSharePerShare; // Accumulated VShares per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public vshare;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint_;

    // The time when VShare mining starts.
    uint256 public poolStartTime;

    // The time when VShare mining ends.
    uint256 public poolEndTime;
    uint256 public lastTimeUpdateRewardRate;
    uint256 public accumulatedRewardPaid;

    uint256 public vSharePerSecond = 0.138888888888888888 ether; // 12000000 vshare / (1000 days * 24h * 60min * 60s)
    uint256 public runningTime = 1000 days;
    uint256 public constant TOTAL_REWARDS = 12000000 ether;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _vshare,
        uint256 _poolStartTime
    ) public {
        if (_poolStartTime == 0 || _poolStartTime < block.timestamp) {
            _poolStartTime = block.timestamp;
        }
        if (_vshare != address(0)) vshare = IERC20(_vshare);
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime.add(runningTime);
        vSharePerSecond = TOTAL_REWARDS.div(runningTime);
        lastTimeUpdateRewardRate = _poolStartTime;
        accumulatedRewardPaid = 0;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "VShareRewardPool: caller is not the operator");
        _;
    }

    modifier onlyOperatorOrTreasury() {
        require(operator == msg.sender || treasury == msg.sender, "VShareRewardPool: caller is not the operator/treasury");
        _;
    }

    function totalAllocPoint() external override view returns (uint256) {
        return totalAllocPoint_;
    }

    function poolLength() external override view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint256 _pid) external override view returns (address _lp, uint256 _allocPoint) {
        PoolInfo memory pool = poolInfo[_pid];
        _lp = address(pool.token);
        _allocPoint = pool.allocPoint;
    }

    function getRewardPerSecond() external override view returns (uint256) {
        return vSharePerSecond;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "VShareRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _token, uint256 _lastRewardTime) public onlyOperator {
        checkPoolDuplicate(_token);
        massUpdatePools();
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accVSharePerShare : 0,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint_ = totalAllocPoint_.add(_allocPoint);
        }
    }

    // Update the given pool's VShare allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint_ = totalAllocPoint_.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(vSharePerSecond);
            return poolEndTime.sub(_fromTime).mul(vSharePerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(vSharePerSecond);
            return _toTime.sub(_fromTime).mul(vSharePerSecond);
        }
    }

    // View function to see pending VShares on frontend.
    function pendingReward(uint256 _pid, address _user) public override view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accVSharePerShare = pool.accVSharePerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _vshareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            accVSharePerShare = accVSharePerShare.add(_vshareReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accVSharePerShare).div(1e18).sub(user.rewardDebt);
    }

    function pendingAllRewards(address _user) external override view returns (uint256 _total) {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _total = _total.add(pendingReward(pid, _user));
        }
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint_ = totalAllocPoint_.add(pool.allocPoint);
        }
        if (totalAllocPoint_ > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _vshareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            pool.accVSharePerShare = pool.accVSharePerShare.add(_vshareReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) external override nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accVSharePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                _safeVShareTransfer(msg.sender, _pending);
                emit RewardPaid(msg.sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accVSharePerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external override nonReentrant {
        _withdraw(msg.sender, _pid, _amount);
    }

    function _withdraw(address _account, uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accVSharePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            _safeVShareTransfer(_account, _pending);
            emit RewardPaid(_account, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accVSharePerShare).div(1e18);
        emit Withdraw(_account, _pid, _amount);
    }

    function withdrawAll(uint256 _pid) external override nonReentrant {
        _withdraw(msg.sender, _pid, userInfo[_pid][msg.sender].amount);
    }

    function harvestAllRewards() external override nonReentrant {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                _withdraw(msg.sender, pid, 0);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe vshare transfer function, just in case if rounding error causes pool to not have enough VShares.
    function _safeVShareTransfer(address _to, uint256 _amount) internal {
        uint256 _vshareBal = vshare.balanceOf(address(this));
        if (_vshareBal > 0) {
            if (_amount > _vshareBal) {
                vshare.safeTransfer(_to, _vshareBal);
            } else {
                vshare.safeTransfer(_to, _amount);
            }
        }
    }

    function updateRewardRate(uint256 _newRate) external override onlyOperatorOrTreasury {
        require(_newRate >= 0.05 ether && _newRate <= 0.5 ether, "out of range");
        uint256 _oldRate = vSharePerSecond;
        massUpdatePools();
        if (block.timestamp > lastTimeUpdateRewardRate) {
            accumulatedRewardPaid = accumulatedRewardPaid.add(block.timestamp.sub(lastTimeUpdateRewardRate).mul(_oldRate));
            lastTimeUpdateRewardRate = block.timestamp;
        }
        if (accumulatedRewardPaid >= TOTAL_REWARDS) {
            poolEndTime = now;
            vSharePerSecond = 0;
        } else {
            vSharePerSecond = _newRate;
            uint256 _secondLeft = TOTAL_REWARDS.sub(accumulatedRewardPaid).div(_newRate);
            poolEndTime = (block.timestamp > poolStartTime) ? block.timestamp.add(_secondLeft) : poolStartTime.add(_secondLeft);
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setTreasury(address _treasury) external onlyOperator {
        treasury = _treasury;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 180 days) {
            // do not allow to drain core token (VShare or lps) if less than 180 days after pool ends
            require(_token != vshare, "vshare");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
