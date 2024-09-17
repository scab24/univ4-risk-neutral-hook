pragma solidity ^0.8.19;

contract HedgeManager {
    function modifyHedgePosition(uint256 priceMovement) external onlyOwner{
        // Detect from mapping if LP is delta-gamma hedge with a power-perp or future / borrowing
        // Change accordingly to price movement and rebalance threshold if only delta-neutral

        
    }
}