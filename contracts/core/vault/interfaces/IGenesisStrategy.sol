// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IGenesisStrategy
 * @notice GenesisVault에서 사용하는 전략 인터페이스
 * @dev GenesisVault와 전략 간의 상호작용을 정의합니다
 */
interface IGenesisStrategy {
  /**
   * @notice 전략을 중지합니다
   * @dev 전략의 모든 활동을 중단하고 자산을 안전하게 보관합니다
   */
  function stop() external;

  /**
   * @notice 전략이 사용하는 자산의 주소를 반환합니다
   * @return 전략이 관리하는 ERC20 토큰의 주소
   */
  function asset() external view returns (address);

  function vault() external view returns (address);

  function reserveExecutionCost(uint256 cost) external;

  function pause() external;

  function unpause() external;

  function utilizedAssets() external view returns (uint256);

  function processAssetsToWithdraw() external;

  function depositCompletedCallback(uint256 amount, bool success) external;

  function withdrawCompletedCallback(uint256 amount, bool success) external;
}
