// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../interfaces/IRegulationStats.sol";
import "../interfaces/ITreasury.sol";

contract RegulationStats is OwnableUpgradeSafe, IRegulationStats {
    using SafeMath for uint256;

    struct Epoch {
        uint256 twap;
        uint256 expanded;
        uint256 bonded;
        uint256 redeemed;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public treasury;

    // flags
    bool private initialized = false;

    mapping(uint256 => Epoch) public epochInfo;

    uint256 public totalBoardroomFunding;
    uint256 public totalDaoFunding;
    uint256 public totalMarketingFunding;
    uint256 public totalInsuranceFunding;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* =================== Events =================== */

    /* =================== Modifier =================== */

    modifier onlyTreasuryOrOwner() {
        require(treasury == msg.sender || owner() == msg.sender, "!owner && !treasury");
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getCurrentEpoch() public view returns (uint256) {
        return ITreasury(treasury).epoch();
    }

    function getNextEpochPoint() public view returns (uint256) {
        return ITreasury(treasury).nextEpochPoint();
    }

    function getEpochInfo(uint256 _start, uint256 _numEpochs) public view returns (uint256[] memory results) {
        results = new uint256[](_numEpochs * 4);
        uint256 _rindex = 0;
        for (uint256 i = 0; i < _numEpochs; i++) {
            Epoch memory _epochInfo = epochInfo[_start + i];
            results[_rindex++] = _epochInfo.twap;
            results[_rindex++] = _epochInfo.expanded;
            results[_rindex++] = _epochInfo.bonded;
            results[_rindex++] = _epochInfo.redeemed;
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(address _treasury) external initializer {
        OwnableUpgradeSafe.__Ownable_init();

        treasury = _treasury;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function addEpochInfo(uint256 epochNumber, uint256 twap, uint256 expanded,
        uint256 boardroomFunding, uint256 daoFunding, uint256 marketingFunding, uint256 insuranceFunding) external override onlyTreasuryOrOwner {
        Epoch storage _epochInfo = epochInfo[epochNumber];
        _epochInfo.twap = twap;
        _epochInfo.expanded = expanded;
        totalBoardroomFunding = totalBoardroomFunding.add(boardroomFunding);
        totalDaoFunding = totalDaoFunding.add(daoFunding);
        totalMarketingFunding = totalMarketingFunding.add(marketingFunding);
        totalInsuranceFunding = totalInsuranceFunding.add(insuranceFunding);
    }

    function addBonded(uint256 epochNumber, uint256 added) external override onlyTreasuryOrOwner {
        Epoch storage _epochInfo = epochInfo[epochNumber];
        _epochInfo.bonded = _epochInfo.bonded.add(added);
    }

    function addRedeemed(uint256 epochNumber, uint256 added) external override onlyTreasuryOrOwner {
        Epoch storage _epochInfo = epochInfo[epochNumber];
        _epochInfo.redeemed = _epochInfo.redeemed.add(added);
    }

    /* ========== EMERGENCY ========== */

    function governanceRecoverUnsupported(IERC20 _token) external onlyOwner {
        _token.transfer(owner(), _token.balanceOf(address(this)));
    }
}
