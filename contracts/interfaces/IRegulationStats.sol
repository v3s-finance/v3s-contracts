// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRegulationStats {
    function addEpochInfo(uint256 epochNumber, uint256 twap, uint256 expanded, uint256 boardroomFunding, uint256 daoFunding, uint256 marketingFunding, uint256 insuranceFunding) external;

    function addBonded(uint256 epochNumber, uint256 added) external;

    function addRedeemed(uint256 epochNumber, uint256 added) external;
}
