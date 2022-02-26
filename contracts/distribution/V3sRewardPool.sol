// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IRewardPool.sol";

// Note that this pool has no minter key of V3S (rewards).
// Instead, the governance will call V3S distributeReward method and send reward to this pool at the beginning.
contract V3sRewardPool is IRewardPool, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. V3Ss to distribute in the pool.
        uint256 lastRewardTime; // Last time that V3Ss distribution occurred.
        uint256 accV3sPerShare; // Accumulated V3Ss per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public v3s;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint_;

    // The time when V3S mining starts.
    uint256 public poolStartTime;

    uint256[] public epochTotalRewards = [300000000 ether, 250000000 ether, 200000000 ether, 150000000 ether];

    // Time when each epoch ends.
    uint256[4] public epochEndTimes;

    // Reward per second for each of 4 weeks (last item is equal to 0 - for sanity).
    uint256[5] public epochV3sPerSecond;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(address _v3s, uint256 _poolStartTime) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_v3s != address(0)) v3s = IERC20(_v3s);

        poolStartTime = _poolStartTime;

        epochEndTimes[0] = poolStartTime + 7 days; // 1st week
        epochEndTimes[1] = epochEndTimes[0] + 7 days; // 2nd week
        epochEndTimes[2] = epochEndTimes[1] + 7 days; // 3rd week
        epochEndTimes[3] = epochEndTimes[2] + 7 days; // 4th week

        epochV3sPerSecond[0] = epochTotalRewards[0].div(7 days);
        epochV3sPerSecond[1] = epochTotalRewards[1].div(7 days);
        epochV3sPerSecond[2] = epochTotalRewards[2].div(7 days);
        epochV3sPerSecond[3] = epochTotalRewards[3].div(7 days);

        epochV3sPerSecond[4] = 0;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "V3sRewardPool: caller is not the operator");
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
        for (uint8 epochId = 0; epochId <= 3; ++epochId) {
            if (block.timestamp <= epochEndTimes[epochId]) return epochV3sPerSecond[epochId];
        }
        return 0;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "V3sRewardPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
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
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accV3sPerShare: 0, isStarted: _isStarted}));
        if (_isStarted) {
            totalAllocPoint_ = totalAllocPoint_.add(_allocPoint);
        }
    }

    // Update the given pool's V3S allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint_ = totalAllocPoint_.sub(pool.allocPoint).add(_allocPoint);
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _fromTime to _toTime.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        for (uint8 epochId = 4; epochId >= 1; --epochId) {
            if (_toTime >= epochEndTimes[epochId - 1]) {
                if (_fromTime >= epochEndTimes[epochId - 1]) {
                    return _toTime.sub(_fromTime).mul(epochV3sPerSecond[epochId]);
                }
                uint256 _generatedReward = _toTime.sub(epochEndTimes[epochId - 1]).mul(epochV3sPerSecond[epochId]);
                if (epochId == 1) {
                    return _generatedReward.add(epochEndTimes[0].sub(_fromTime).mul(epochV3sPerSecond[0]));
                }
                for (epochId = epochId - 1; epochId >= 1; --epochId) {
                    if (_fromTime >= epochEndTimes[epochId - 1]) {
                        return _generatedReward.add(epochEndTimes[epochId].sub(_fromTime).mul(epochV3sPerSecond[epochId]));
                    }
                    _generatedReward = _generatedReward.add(epochEndTimes[epochId].sub(epochEndTimes[epochId - 1]).mul(epochV3sPerSecond[epochId]));
                }
                return _generatedReward.add(epochEndTimes[0].sub(_fromTime).mul(epochV3sPerSecond[0]));
            }
        }
        return _toTime.sub(_fromTime).mul(epochV3sPerSecond[0]);
    }

    // View function to see pending V3Ss on frontend.
    function pendingReward(uint256 _pid, address _user) public override view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accV3sPerShare = pool.accV3sPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _v3sReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            accV3sPerShare = accV3sPerShare.add(_v3sReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accV3sPerShare).div(1e18).sub(user.rewardDebt);
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
            uint256 _v3sReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint_);
            pool.accV3sPerShare = pool.accV3sPerShare.add(_v3sReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) external override nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accV3sPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeV3sTransfer(msg.sender, _pending);
                emit RewardPaid(msg.sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accV3sPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external override nonReentrant {
        _withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function _withdraw(address _account, uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accV3sPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeV3sTransfer(_account, _pending);
            emit RewardPaid(_account, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accV3sPerShare).div(1e18);
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
    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe v3s transfer function, just in case if rounding error causes pool to not have enough V3Ss.
    function safeV3sTransfer(address _to, uint256 _amount) internal {
        uint256 _v3sBal = v3s.balanceOf(address(this));
        if (_v3sBal > 0) {
            if (_amount > _v3sBal) {
                v3s.safeTransfer(_to, _v3sBal);
            } else {
                v3s.safeTransfer(_to, _amount);
            }
        }
    }

    function updateRewardRate(uint256) external override {
        revert("Not support");
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        if (block.timestamp < epochEndTimes[1] + 30 days) {
            // do not allow to drain token if less than 30 days after farming
            require(_token != v3s, "!v3s");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "!pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
