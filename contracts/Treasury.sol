// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IRegulationStats.sol";
import "./interfaces/IRewardPool.sol";

// V3S FINANCE
contract Treasury is ITreasury, ContractGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private epoch_ = 0;
    uint256 private epochLength_ = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public v3s;
    address public vbond;

    address public override boardroom;
    address public v3sOracle;

    // price
    uint256 public v3sPriceOne;
    uint256 public v3sPriceCeiling;

    uint256 public seigniorageSaved;

    uint256 public nextSupplyTarget;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of V3S price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    uint256 public override previousEpochV3sPrice;
    uint256 public allocateSeigniorageSalary;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra V3S during debt phase

    address public override daoFund;
    uint256 public override daoFundSharedPercent; // 3000 (30%)

    address public override marketingFund;
    uint256 public override marketingFundSharedPercent; // 1000 (10%)

    address public override insuranceFund;
    uint256 public override insuranceFundSharedPercent; // 2000 (20%)

    address public regulationStats;
    address public vshareRewardPool;
    uint256 public vshareRewardPoolExpansionRate;
    uint256 public vshareRewardPoolContractionRate;

    /* =================== Added variables =================== */
    // ...

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 v3sAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 v3sAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event FundingAdded(uint256 indexed epoch, uint256 timestamp, uint256 price, uint256 expanded, uint256 boardroomFunded, uint256 daoFunded, uint256 marketingFunded, uint256 insuranceFund);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(now >= _nextEpochPoint, "Treasury: not opened yet");

        _;

        lastEpochTime = _nextEpochPoint;
        epoch_ = epoch_.add(1);
        epochSupplyContractionLeft = (getV3sPrice() > v3sPriceCeiling) ? 0 : IERC20(v3s).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(v3s).operator() == address(this) &&
                IBasisAsset(vbond).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function epoch() public override view returns (uint256) {
        return epoch_;
    }

    function nextEpochPoint() public override view returns (uint256) {
        return lastEpochTime.add(nextEpochLength());
    }

    function nextEpochLength() public override view returns (uint256) {
        return epochLength_;
    }

    function getPegPrice() external override view returns (int256) {
        return IOracle(v3sOracle).getPegPrice();
    }

    function getPegPriceUpdated() external override view returns (int256) {
        return IOracle(v3sOracle).getPegPriceUpdated();
    }

    // oracle
    function getV3sPrice() public override view returns (uint256 v3sPrice) {
        try IOracle(v3sOracle).consult(v3s, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult V3S price from the oracle");
        }
    }

    function getV3sUpdatedPrice() public override view returns (uint256 _v3sPrice) {
        try IOracle(v3sOracle).twap(v3s, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult V3S price from the oracle");
        }
    }

    function boardroomSharedPercent() external override view returns (uint256) {
        return uint256(10000).sub(daoFundSharedPercent).sub(marketingFundSharedPercent).sub(insuranceFundSharedPercent);
    }

    // budget
    function getReserve() external view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableV3sLeft() external view returns (uint256 _burnableV3sLeft) {
        uint256 _v3sPrice = getV3sPrice();
        if (_v3sPrice <= v3sPriceOne) {
            uint256 _bondMaxSupply = IERC20(v3s).totalSupply().mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(vbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableV3s = _maxMintableBond.mul(getBondDiscountRate()).div(1e18);
                _burnableV3sLeft = Math.min(epochSupplyContractionLeft, _maxBurnableV3s);
            }
        }
    }

    function getRedeemableBonds() external view returns (uint256 _redeemableBonds) {
        uint256 _v3sPrice = getV3sPrice();
        if (_v3sPrice > v3sPriceCeiling) {
            uint256 _totalV3s = IERC20(v3s).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalV3s.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public override view returns (uint256 _rate) {
        uint256 _v3sPrice = getV3sPrice();
        if (_v3sPrice <= v3sPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = v3sPriceOne;
            } else {
                uint256 _bondAmount = v3sPriceOne.mul(1e18).div(_v3sPrice); // to burn 1 V3S
                uint256 _discountAmount = _bondAmount.sub(v3sPriceOne).mul(discountPercent).div(10000);
                _rate = v3sPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public override view returns (uint256 _rate) {
        uint256 _v3sPrice = getV3sPrice();
        if (_v3sPrice > v3sPriceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = v3sPriceOne;
            } else {
                uint256 _premiumAmount = _v3sPrice.sub(v3sPriceOne).mul(premiumPercent).div(10000);
                _rate = v3sPriceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getNextExpansionRate() public override view returns (uint256 _rate) {
        if (epoch_ < bootstrapEpochs) {// 28 first epochs with 4.5% expansion
            _rate = bootstrapSupplyExpansionPercent;
        } else {
            uint256 _twap = getV3sUpdatedPrice();
            if (_twap >= v3sPriceCeiling) {
                uint256 _percentage = _twap.sub(v3sPriceOne); // 1% = 1e16
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                _rate = _percentage.div(1e12);
            }
        }
    }

    function getNextExpansionAmount() external override view returns (uint256) {
        uint256 _rate = getNextExpansionRate();
        return IERC20(v3s).totalSupply().mul(_rate).div(1e6);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _v3s,
        address _vbond,
        address _v3sOracle,
        address _boardroom,
        uint256 _startTime
    ) public notInitialized {
        v3s = _v3s;
        vbond = _vbond;
        v3sOracle = _v3sOracle;
        boardroom = _boardroom;

        startTime = _startTime;
        epochLength_ = 6 hours;
        lastEpochTime = _startTime.sub(6 hours);

        v3sPriceOne = 10**18; // This is to allow a PEG of 1 V3S per VVS
        v3sPriceCeiling = v3sPriceOne.mul(1001).div(1000);

        maxSupplyExpansionPercent = 300; // Upto 3.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn V3S and mint VBOND)
        maxDebtRatioPercent = 4500; // Upto 35% supply of VBOND to purchase

        maxDiscountRate = 13e17; // 30% - when purchasing bond
        maxPremiumRate = 13e17; // 30% - when redeeming bond

        discountPercent = 0; // no discount
        premiumPercent = 6500; // 65% premium

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(v3s).balanceOf(address(this));

        nextSupplyTarget = 2000000000 ether; // 2B supply is the next target to reduce expansion rate

        vshareRewardPoolExpansionRate = 0.138888888888888888 ether; // 12000000 vshare / (1000 days * 24h * 60min * 60s)
        vshareRewardPoolContractionRate = 0.2777777777777778 ether; // 2x

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function resetStartTime(uint256 _startTime) external onlyOperator {
        require(epoch_ == 0, "already started");
        startTime = _startTime;
        lastEpochTime = _startTime.sub(epochLength_);
    }

    function setEpochLength(uint256 _epochLength) external onlyOperator {
        require(_epochLength >= 1 hours && _epochLength <= 24 hours, "out of range");
        epochLength_ = _epochLength;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setRegulationStats(address _regulationStats) external onlyOperator {
        regulationStats = _regulationStats;
    }

    function setVshareRewardPool(address _vshareRewardPool) external onlyOperator {
        vshareRewardPool = _vshareRewardPool;
    }

    function setVshareRewardPoolRates(uint256 _vshareRewardPoolExpansionRate, uint256 _vshareRewardPoolContractionRate) external onlyOperator {
        require(_vshareRewardPoolExpansionRate <= 0.5 ether && _vshareRewardPoolExpansionRate <= 0.5 ether, "too high");
        require(_vshareRewardPoolContractionRate >= 0.05 ether && _vshareRewardPoolContractionRate >= 0.05 ether, "too low");
        vshareRewardPoolExpansionRate = _vshareRewardPoolExpansionRate;
        vshareRewardPoolContractionRate = _vshareRewardPoolContractionRate;
    }

    function setV3sOracle(address _v3sOracle) external onlyOperator {
        v3sOracle = _v3sOracle;
    }

    function setV3sPriceCeiling(uint256 _v3sPriceCeiling) external onlyOperator {
        require(_v3sPriceCeiling >= v3sPriceOne && _v3sPriceCeiling <= v3sPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        v3sPriceCeiling = _v3sPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _marketingFund,
        uint256 _marketingFundSharedPercent,
        address _insuranceFund,
        uint256 _insuranceFundSharedPercent
    ) external onlyOperator {
        require(_daoFundSharedPercent == 0 || _daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 4000, "out of range"); // <= 40%
        require(_marketingFundSharedPercent == 0 || _marketingFund != address(0), "zero");
        require(_marketingFundSharedPercent <= 2000, "out of range"); // <= 20%
        require(_insuranceFundSharedPercent == 0 || _insuranceFund != address(0), "zero");
        require(_insuranceFundSharedPercent <= 3000, "out of range"); // <= 30%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        marketingFund = _marketingFund;
        marketingFundSharedPercent = _marketingFundSharedPercent;
        insuranceFund = _insuranceFund;
        insuranceFundSharedPercent = _insuranceFundSharedPercent;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyOperator {
        require(_allocateSeigniorageSalary <= 10000 ether, "Treasury: dont pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function setNextSupplyTarget(uint256 _target) external onlyOperator {
        require(_target > IERC20(v3s).totalSupply(), "too small");
        nextSupplyTarget = _target;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateV3sPrice() internal {
        try IOracle(v3sOracle).update() {} catch {}
    }

    function buyBonds(uint256 _v3sAmount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_v3sAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 v3sPrice = getV3sPrice();
        require(v3sPrice == targetPrice, "Treasury: V3S price moved");
        require(
            v3sPrice < v3sPriceOne, // price < $1
            "Treasury: v3sPrice not eligible for bond purchase"
        );

        require(_v3sAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        address _v3s = v3s;
        uint256 _bondAmount = _v3sAmount.mul(_rate).div(1e18);
        uint256 _v3sSupply = IERC20(v3s).totalSupply();
        uint256 newBondSupply = IERC20(vbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= _v3sSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(_v3s).burnFrom(msg.sender, _v3sAmount);
        IBasisAsset(vbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_v3sAmount);
        _updateV3sPrice();
        if (regulationStats != address(0)) IRegulationStats(regulationStats).addBonded(epoch_, _bondAmount);

        emit BoughtBonds(msg.sender, _v3sAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 v3sPrice = getV3sPrice();
        require(v3sPrice == targetPrice, "Treasury: V3S price moved");
        require(
            v3sPrice > v3sPriceCeiling, // price > $1.01
            "Treasury: v3sPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _v3sAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(v3s).balanceOf(address(this)) >= _v3sAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _v3sAmount));
        allocateSeigniorageSalary = 1000 ether; // 1000 V3S salary for calling allocateSeigniorage()

        IBasisAsset(vbond).burnFrom(msg.sender, _bondAmount);
        IERC20(v3s).safeTransfer(msg.sender, _v3sAmount);

        _updateV3sPrice();
        if (regulationStats != address(0)) IRegulationStats(regulationStats).addRedeemed(epoch_, _v3sAmount);

        emit RedeemedBonds(msg.sender, _v3sAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount, uint256 _expanded) internal {
        address _v3s = v3s;
        IBasisAsset(_v3s).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(_v3s).transfer(daoFund, _daoFundSharedAmount);
        }

        uint256 _marketingFundSharedAmount = 0;
        if (marketingFundSharedPercent > 0) {
            _marketingFundSharedAmount = _amount.mul(marketingFundSharedPercent).div(10000);
            IERC20(_v3s).transfer(marketingFund, _marketingFundSharedAmount);
        }

        uint256 _insuranceFundSharedAmount = 0;
        if (insuranceFundSharedPercent > 0) {
            _insuranceFundSharedAmount = _amount.mul(insuranceFundSharedPercent).div(10000);
            IERC20(_v3s).transfer(insuranceFund, _insuranceFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_marketingFundSharedAmount).sub(_insuranceFundSharedAmount);

        IERC20(_v3s).safeIncreaseAllowance(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);

        if (regulationStats != address(0)) IRegulationStats(regulationStats).addEpochInfo(epoch_.add(1), previousEpochV3sPrice, _expanded,
            _amount, _daoFundSharedAmount, _marketingFundSharedAmount, _insuranceFundSharedAmount);
        emit FundingAdded(epoch_, block.timestamp, previousEpochV3sPrice, _expanded,
            _amount, _daoFundSharedAmount, _marketingFundSharedAmount, _insuranceFundSharedAmount);
    }

    function allocateSeigniorage() external onlyOneBlock checkEpoch checkOperator nonReentrant {
        _updateV3sPrice();
        previousEpochV3sPrice = getV3sPrice();
        address _v3s = v3s;
        uint256 _supply = IERC20(_v3s).totalSupply();
        uint256 _nextSupplyTarget = nextSupplyTarget;
        if (_supply >= _nextSupplyTarget) {
            nextSupplyTarget = _nextSupplyTarget.mul(12500).div(10000); // +25%
            maxSupplyExpansionPercent = maxSupplyExpansionPercent.mul(9500).div(10000); // -5%
            if (maxSupplyExpansionPercent < 25) {
                maxSupplyExpansionPercent = 25; // min 0.25%
            }
        }
        uint256 _seigniorage;
        if (epoch_ < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _seigniorage = _supply.mul(bootstrapSupplyExpansionPercent).div(10000);
            _sendToBoardroom(_seigniorage, _seigniorage);
        } else {
            address _vshareRewardPool = vshareRewardPool;
            if (previousEpochV3sPrice > v3sPriceCeiling) {
                // Expansion ($V3S Price > 1 $ETH): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(vbond).totalSupply();
                uint256 _percentage = previousEpochV3sPrice.sub(v3sPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = _supply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    _seigniorage = _supply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom, _seigniorage);
                } else {
                    // function addEpochInfo(uint256 epochNumber, uint256 twap, uint256 expanded, uint256 boardroomFunding, uint256 daoFunding, uint256 marketingFunding, uint256 insuranceFunding) external;
                    if (regulationStats != address(0)) IRegulationStats(regulationStats).addEpochInfo(epoch_.add(1), previousEpochV3sPrice, 0, 0, 0, 0, 0);
                    emit FundingAdded(epoch_, block.timestamp, previousEpochV3sPrice, 0, 0, 0, 0, 0);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(_v3s).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
                if (_vshareRewardPool != address(0) && IRewardPool(_vshareRewardPool).getRewardPerSecond() != vshareRewardPoolExpansionRate) {
                    IRewardPool(_vshareRewardPool).updateRewardRate(vshareRewardPoolExpansionRate);
                }
            } else if (previousEpochV3sPrice < v3sPriceOne) {
                if (_vshareRewardPool != address(0) && IRewardPool(_vshareRewardPool).getRewardPerSecond() != vshareRewardPoolContractionRate) {
                    IRewardPool(_vshareRewardPool).updateRewardRate(vshareRewardPoolContractionRate);
                }
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(_v3s).mint(address(msg.sender), allocateSeigniorageSalary);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(v3s), "v3s");
        require(address(_token) != address(vbond), "bond");
        _token.safeTransfer(_to, _amount);
    }

    function tokenTransferOperator(address _token, address _operator) external onlyOperator {
        IBasisAsset(_token).transferOperator(_operator);
    }

    function tokenTransferOwnership(address _token, address _operator) external onlyOperator {
        IBasisAsset(_token).transferOwnership(_operator);
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(address _boardRoomOrToken, address _token, uint256 _amount, address _to) external onlyOperator {
        IBoardroom(_boardRoomOrToken).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
