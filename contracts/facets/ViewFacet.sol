// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibBaseVolStrike } from "../libraries/LibBaseVolStrike.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { Round, FilledOrder, ProductRound, SettlementResult, PriceInfo } from "../types/Types.sol";

contract ViewFacet {
  using LibBaseVolStrike for LibBaseVolStrike.DiamondStorage;

  function commissionfee() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.commissionfee;
  }

  function addresses() public view returns (address, address, address, address) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return (bvs.adminAddress, bvs.operatorAddress, address(bvs.clearingHouse), address(bvs.token));
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    uint256 depositBalance = bvs.clearingHouse.userBalances(user);
    uint256 couponBalance = bvs.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function rounds(uint256 epoch, uint256 productId) public view returns (ProductRound memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    Round storage round = bvs.rounds[epoch];
    if (round.epoch == 0) {
      (uint256 startTime, uint256 endTime) = _epochTimes(epoch);
      return
        // return virtual value
        ProductRound({
          epoch: epoch,
          startTimestamp: startTime,
          endTimestamp: endTime,
          isStarted: false,
          isSettled: false,
          startPrice: 0,
          endPrice: 0
        });
    }
    return
      // return storage value
      ProductRound({
        epoch: round.epoch,
        startTimestamp: round.startTimestamp,
        endTimestamp: round.endTimestamp,
        isStarted: round.isStarted,
        isSettled: round.isSettled,
        startPrice: round.startPrice[productId],
        endPrice: round.endPrice[productId]
      });
  }

  function filledOrders(uint256 epoch) public view returns (FilledOrder[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.filledOrders[epoch];
  }

  function filledOrdersWithResult(
    uint256 epoch,
    uint256 chunkSize,
    uint256 offset
  ) public view returns (FilledOrder[] memory, SettlementResult[] memory) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] memory orders = bvs.filledOrders[epoch];
    if (offset >= orders.length) {
      return (new FilledOrder[](0), new SettlementResult[](0));
    }
    uint256 end = offset + chunkSize;
    if (end > orders.length) {
      end = orders.length;
    }
    FilledOrder[] memory chunkedOrders = new FilledOrder[](end - offset);
    SettlementResult[] memory chunkedResults = new SettlementResult[](end - offset);
    for (uint i = offset; i < end; i++) {
      chunkedOrders[i - offset] = orders[i];
      chunkedResults[i - offset] = bvs.settlementResults[orders[i].idx];
    }
    return (chunkedOrders, chunkedResults);
  }

  /// @notice Get user's filled orders with pagination support
  /// @param epoch The epoch to query
  /// @param user The user address
  /// @param startIndex Starting index in the orders array
  /// @param maxResults Maximum number of orders to process
  /// @return userOrders Array of user's orders
  /// @return totalOrders Total number of orders in the epoch
  /// @return nextIndex Next page start index (0 if last page)
  function userFilledOrdersPaginated(
    uint256 epoch,
    address user,
    uint256 startIndex,
    uint256 maxResults
  ) 
    public 
    view 
    returns (
      FilledOrder[] memory userOrders,
      uint256 totalOrders,
      uint256 nextIndex
    ) 
  {
    require(maxResults > 0 && maxResults <= 200, "Invalid page size");
    require(user != address(0), "Invalid user address");
    
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];
    totalOrders = orders.length;
    
    // Return empty if start index is out of bounds
    if (startIndex >= totalOrders) {
      return (new FilledOrder[](0), totalOrders, 0);
    }
    
    // Calculate end index
    uint256 endIndex = startIndex + maxResults;
    if (endIndex > totalOrders) {
      endIndex = totalOrders;
    }
    
    // First pass: count user orders in this page
    uint256 userOrderCount = 0;
    for (uint256 i = startIndex; i < endIndex; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        userOrderCount++;
      }
    }
    
    // Second pass: collect user orders
    userOrders = new FilledOrder[](userOrderCount);
    uint256 idx = 0;
    for (uint256 i = startIndex; i < endIndex; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        userOrders[idx] = order;
        idx++;
      }
    }
    
    // Calculate next index
    nextIndex = endIndex < totalOrders ? endIndex : 0;
    
    return (userOrders, totalOrders, nextIndex);
  }

  /// @notice Get user's filled orders (backward compatible, limited to 100 orders)
  /// @param epoch The epoch to query
  /// @param user The user address
  /// @return User's filled orders (max 100 orders processed)
  function userFilledOrders(
    uint256 epoch,
    address user
  ) public view returns (FilledOrder[] memory) {
    (FilledOrder[] memory orders,,) = userFilledOrdersPaginated(epoch, user, 0, 100);
    return orders;
  }

  /// @notice Get count of user's filled orders in an epoch
  /// @param epoch The epoch to query
  /// @param user The user address
  /// @return count Number of user's orders
  function userFilledOrderCount(
    uint256 epoch,
    address user
  ) external view returns (uint256 count) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];
    
    for (uint256 i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        count++;
      }
    }
    
    return count;
  }

  /// @notice Get filled order by index
  /// @param epoch The epoch to query
  /// @param orderIndex The order index
  /// @return order The filled order
  function getFilledOrderByIndex(
    uint256 epoch,
    uint256 orderIndex
  ) external view returns (FilledOrder memory order) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    FilledOrder[] storage orders = bvs.filledOrders[epoch];
    
    require(orderIndex < orders.length, "Invalid order index");
    
    return orders[orderIndex];
  }

  function lastFilledOrderId() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.lastFilledOrderId;
  }

  function lastSettledFilledOrderId() public view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.lastSettledFilledOrderId;
  }

  /// @notice Get price infos with pagination support
  /// @param startIndex Starting index
  /// @param maxResults Maximum number of results
  /// @return priceInfoArray Array of price infos
  /// @return totalCount Total number of price infos
  /// @return nextIndex Next page start index (0 if last page)
  function priceInfosPaginated(
    uint256 startIndex,
    uint256 maxResults
  ) 
    external 
    view 
    returns (
      PriceInfo[] memory priceInfoArray,
      uint256 totalCount,
      uint256 nextIndex
    ) 
  {
    require(maxResults > 0 && maxResults <= 100, "Invalid page size");
    
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    totalCount = bvs.priceIdCount;
    
    // Return empty if start index is out of bounds
    if (startIndex >= totalCount) {
      return (new PriceInfo[](0), totalCount, 0);
    }
    
    // Calculate end index
    uint256 endIndex = startIndex + maxResults;
    if (endIndex > totalCount) {
      endIndex = totalCount;
    }
    
    // Create result array
    uint256 resultCount = endIndex - startIndex;
    priceInfoArray = new PriceInfo[](resultCount);
    
    for (uint256 i = 0; i < resultCount; i++) {
      priceInfoArray[i] = bvs.priceInfos[startIndex + i];
    }
    
    // Calculate next index
    nextIndex = endIndex < totalCount ? endIndex : 0;
    
    return (priceInfoArray, totalCount, nextIndex);
  }

  /// @notice Get all price infos (backward compatible, limited to 50)
  /// @return Array of price infos (max 50)
  function priceInfos() external view returns (PriceInfo[] memory) {
    (PriceInfo[] memory infos,,) = this.priceInfosPaginated(0, 50);
    return infos;
  }

  /// @notice Get price info by product ID
  /// @param productId The product ID
  /// @return info The price info
  function getPriceInfo(uint256 productId) external view returns (PriceInfo memory info) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    require(productId < bvs.priceIdCount, "Invalid product ID");
    return bvs.priceInfos[productId];
  }

  /// @notice Get total number of price infos
  /// @return count The count
  function priceInfoCount() external view returns (uint256 count) {
    LibBaseVolStrike.DiamondStorage storage bvs = LibBaseVolStrike.diamondStorage();
    return bvs.priceIdCount;
  }

  // Internal functions
  function _getStartTimestamp() internal view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage ds = LibBaseVolStrike.diamondStorage();
    return ds.startTimestamp;
  }

  function _getIntervalSeconds() internal view returns (uint256) {
    LibBaseVolStrike.DiamondStorage storage ds = LibBaseVolStrike.diamondStorage();
    return ds.intervalSeconds;
  }

  function _epochTimes(uint256 epoch) internal view returns (uint256 startTime, uint256 endTime) {
    if (epoch < 0) revert LibBaseVolStrike.InvalidEpoch();
    startTime = _getStartTimestamp() + (epoch * _getIntervalSeconds());
    endTime = startTime + _getIntervalSeconds();
    return (startTime, endTime);
  }
}
