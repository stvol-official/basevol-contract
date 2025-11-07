// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibGenesisVaultStorage } from "../libraries/LibGenesisVaultStorage.sol";
import { LibGenesisVault } from "../libraries/LibGenesisVault.sol";
import { LibERC20 } from "../libraries/LibERC20.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { IGenesisStrategy } from "../../core/vault/interfaces/IGenesisStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title VaultCoreFacet
 * @notice Core ERC4626/ERC7540 vault operations (deposit, mint, withdraw, redeem, requests, operators)
 * @dev Unified facet combining async request creation and claim operations
 */
contract VaultCoreFacet {
  using SafeERC20 for IERC20;
  using Math for uint256;

  uint256 internal constant FLOAT_PRECISION = 1e18;
  uint256 internal constant MINIMUM_FIRST_DEPOSIT = 1000e6; // 1000 USDC

  // ============ Events ============
  event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

  event Withdraw(
    address indexed sender,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );

  event VaultState(uint256 totalAssets, uint256 totalSupply);

  /// @dev Emitted when performance fee is charged
  event PerformanceFeeCharged(
    address indexed user,
    uint256 feeAmount,
    uint256 currentSharePrice,
    uint256 userWAEP
  );

  event DepositRequest(
    address indexed controller,
    address indexed owner,
    uint256 indexed requestId,
    address sender,
    uint256 assets
  );

  event RedeemRequest(
    address indexed controller,
    address indexed owner,
    uint256 indexed requestId,
    address sender,
    uint256 shares
  );

  event OperatorSet(address indexed controller, address indexed operator, bool approved);

  // ============ Modifiers ============
  modifier onlyControllerOrOperator(address controller) {
    require(
      msg.sender == controller || LibGenesisVaultStorage.layout().operators[controller][msg.sender],
      "VaultCoreFacet: Not authorized"
    );
    _;
  }

  // ============ ERC7540 Operator Management ============

  /**
   * @notice Set operator approval for ERC7540
   * @param operator The operator address
   * @param approved True to approve, false to revoke
   * @return success True if successful
   */
  function setOperator(address operator, bool approved) external returns (bool) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    s.operators[msg.sender][operator] = approved;
    emit OperatorSet(msg.sender, operator, approved);
    return true;
  }

  /**
   * @notice Check if operator is approved
   * @param controller The controller address
   * @param operator The operator address
   * @return approved True if operator is approved
   */
  function isOperator(address controller, address operator) external view returns (bool) {
    return LibGenesisVaultStorage.layout().operators[controller][operator];
  }

  // ============ ERC7540 Request Functions ============

  /**
   * @notice Request deposit to vault
   * @param assets The amount of assets to deposit
   * @param controller The address that will control the request
   * @param owner The address that owns the assets
   * @return requestId The ID of the request (epoch number)
   */
  function requestDeposit(
    uint256 assets,
    address controller,
    address owner
  ) external returns (uint256 requestId) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // ERC7540: owner MUST equal msg.sender unless owner has approved msg.sender as operator
    require(
      msg.sender == owner || s.operators[owner][msg.sender],
      "VaultCoreFacet: Not authorized"
    );

    // Transfer assets to vault
    s.asset.safeTransferFrom(owner, address(this), assets);

    return _requestDepositInternal(assets, controller, owner, true);
  }

  /**
   * @notice Deposit from ClearingHouse without entry fee
   * @dev Only callable by ClearingHouse contract
   * @param assets The amount of assets to deposit (already transferred)
   * @param user The address of the user
   * @return requestId The ID of the request (epoch number)
   */
  function depositFromClearingHouse(
    uint256 assets,
    address user
  ) external returns (uint256 requestId) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    require(msg.sender == s.clearingHouse, "VaultCoreFacet: Not authorized");

    // Assets are already transferred by ClearingHouse
    // controller and owner are both the user, no entry fee applied
    return _requestDepositInternal(assets, user, user, false);
  }

  /**
   * @notice Internal function to handle deposit request logic
   * @param assets The amount of assets to deposit
   * @param controller The address that will control the request
   * @param owner The address that owns the assets
   * @param applyFee Whether to apply entry fee
   * @return requestId The ID of the request (epoch number)
   */
  function _requestDepositInternal(
    uint256 assets,
    address controller,
    address owner,
    bool applyFee
  ) internal returns (uint256 requestId) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    require(assets > 0, "VaultCoreFacet: Zero assets");
    require(!s.paused && !s.shutdown, "VaultCoreFacet: Vault not active");

    // Validate against deposit limits
    uint256 maxDepositAmount = LibGenesisVault.calculateMaxDepositRequest(owner);
    require(assets <= maxDepositAmount, "VaultCoreFacet: Deposit exceeds limit");

    // Apply entry cost if required
    uint256 netAssets = assets;
    if (applyFee) {
      uint256 entryCostAmount = s.entryCost;
      netAssets = assets - entryCostAmount;

      // Transfer entry cost immediately to fee recipient
      LibGenesisVault.transferFeesToRecipient(entryCostAmount, "entry");
    }

    // Get current epoch from BaseVol system
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking with net assets (after fee)
    s.userEpochDepositAssets[controller][currentEpoch] += netAssets;
    s.roundData[currentEpoch].totalRequestedDepositAssets += netAssets;

    // Add to user's epoch list (avoid duplicates)
    if (s.userEpochDepositAssets[controller][currentEpoch] == netAssets) {
      s.userDepositEpochs[controller].push(currentEpoch);

      // Add user to epoch deposit users list for auto-processing (avoid duplicates)
      _addUserToEpochDepositList(controller, currentEpoch);
    }

    emit DepositRequest(controller, owner, requestId, msg.sender, assets);

    return requestId;
  }

  /**
   * @notice Request redeem from vault
   * @param shares The amount of shares to redeem
   * @param controller The address that will control the request
   * @param owner The address that owns the shares
   * @return requestId The ID of the request (epoch number)
   */
  function requestRedeem(
    uint256 shares,
    address controller,
    address owner
  ) external returns (uint256 requestId) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    require(shares > 0, "VaultCoreFacet: Zero shares");
    require(!s.paused && !s.shutdown, "VaultCoreFacet: Vault not active");

    // ERC7540: Redeem Request approval may come from ERC-20 approval OR operator approval
    if (msg.sender != owner) {
      bool hasOperatorApproval = s.operators[owner][msg.sender];
      if (!hasOperatorApproval) {
        LibERC20._spendAllowance(owner, msg.sender, shares);
      }
      // Note: If operator, no allowance deduction per ERC7540 spec
    }
    LibERC20._burn(owner, shares);

    // Create request
    uint256 currentEpoch = LibGenesisVault.getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking
    s.userEpochRedeemShares[controller][currentEpoch] += shares;
    s.roundData[currentEpoch].totalRequestedRedeemShares += shares;

    // Add to user's epoch list (avoid duplicates)
    if (s.userEpochRedeemShares[controller][currentEpoch] == shares) {
      s.userRedeemEpochs[controller].push(currentEpoch);

      // Add user to epoch redeem users list for auto-processing (avoid duplicates)
      _addUserToEpochRedeemList(controller, currentEpoch);
    }

    emit RedeemRequest(controller, owner, requestId, msg.sender, shares);

    return requestId;
  }

  // ============ ERC7540 Request State Query Functions ============

  /**
   * @notice Get pending deposit request amount
   * @param requestId The ID of the request (epoch number)
   * @param controller The address to check
   * @return assets The amount of pending deposit assets
   */
  function pendingDepositRequest(
    uint256 requestId,
    address controller
  ) external view returns (uint256 assets) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Claimable state for deposit
    // Check if the epoch is settled (i.e., claimable)
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
    if (roundData.isSettled) {
      return 0; // Assets are in claimable state, not pending
    }

    // Return the pending assets for this controller in this epoch
    return s.userEpochDepositAssets[controller][epoch];
  }

  /**
   * @notice Get claimable deposit request amount
   * @param requestId The ID of the request (epoch number)
   * @param controller The address to check
   * @return assets The amount of claimable deposit assets
   */
  function claimableDepositRequest(
    uint256 requestId,
    address controller
  ) external view returns (uint256 assets) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Pending state for deposit
    // Check if the epoch is settled (i.e., claimable)
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
    if (!roundData.isSettled) {
      return 0; // Assets are still in pending state, not claimable
    }

    // Calculate claimable assets for this specific epoch
    return LibGenesisVault.calculateClaimableForEpoch(controller, epoch, true);
  }

  /**
   * @notice Get pending redeem request amount
   * @param requestId The ID of the request (epoch number)
   * @param controller The address to check
   * @return shares The amount of pending redemption shares
   */
  function pendingRedeemRequest(
    uint256 requestId,
    address controller
  ) external view returns (uint256 shares) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Claimable state for redeem
    // Check if the epoch is settled (i.e., claimable)
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
    if (roundData.isSettled) {
      return 0; // Shares are in claimable state, not pending
    }

    // Return the pending shares for this controller in this epoch
    return s.userEpochRedeemShares[controller][epoch];
  }

  /**
   * @notice Get claimable redeem request amount
   * @param requestId The ID of the request (epoch number)
   * @param controller The address to check
   * @return shares The amount of claimable redemption shares
   */
  function claimableRedeemRequest(
    uint256 requestId,
    address controller
  ) external view returns (uint256 shares) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Pending state for redeem
    // Check if the epoch is settled (i.e., claimable)
    LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
    if (!roundData.isSettled) {
      return 0; // Shares are still in pending state, not claimable
    }

    // Calculate claimable shares for this specific epoch
    return LibGenesisVault.calculateClaimableForEpoch(controller, epoch, false);
  }

  // ============ ERC7540 Deposit/Mint (3-parameter) ============

  /**
   * @notice ERC7540 deposit (claim from async request)
   * @dev Epoch-based with automatic FIFO processing
   * @dev Processes up to 50 epochs per call to prevent gas issues
   * @param assets The amount of assets to claim
   * @param receiver The address to receive the shares
   * @param controller The address that controls the request
   * @return shares The amount of shares minted
   */
  function deposit(
    uint256 assets,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 shares) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Epoch-based: Calculate total claimable across user's epochs
    uint256 totalClaimable = _calculateClaimableDepositAssetsAcrossEpochs(controller);
    require(totalClaimable >= assets, "VaultCoreFacet: Insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    // Only process up to 50 epochs per call for gas efficiency
    uint256 remainingAssets = assets;
    uint256 totalShares = 0;

    uint256[] memory userEpochs = s.userDepositEpochs[controller];
    uint256 epochsToCheck = userEpochs.length > 50 ? 50 : userEpochs.length;

    for (uint256 i = 0; i < epochsToCheck && remainingAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableAssets = LibGenesisVault.calculateClaimableForEpoch(controller, epoch, true);
      uint256 assetsToProcess = Math.min(remainingAssets, claimableAssets);

      if (assetsToProcess > 0) {
        // SECURITY: Minimum first deposit check (donation attack prevention)
        if (s.totalSupply == 0 && assetsToProcess < MINIMUM_FIRST_DEPOSIT) {
          revert("VaultCoreFacet: First deposit too small");
        }

        // Use epoch-specific share price
        // shares = assets * (10^shareDecimals) / sharePrice
        uint256 epochShares = (assetsToProcess * (10 ** s.decimals)) / roundData.sharePrice;
        
        // SECURITY: Zero share prevention (donation attack prevention)
        // Skip this epoch instead of reverting to prevent griefing attack
        if (epochShares == 0) {
          continue; // Skip to next epoch
        }
        
        totalShares += epochShares;

        // Update WAEP for the receiver with epoch-specific share price
        _updateUserWAEP(receiver, epochShares, roundData.sharePrice);

        // Update global claimed amount
        roundData.claimedDepositAssets += assetsToProcess;

        // Update user-specific claimed amount
        s.userEpochClaimedDepositAssets[controller][epoch] += assetsToProcess;

        remainingAssets -= assetsToProcess;

        // If this epoch is fully claimed, remove it from the list
        if (
          s.userEpochDepositAssets[controller][epoch] ==
          s.userEpochClaimedDepositAssets[controller][epoch]
        ) {
          _removeEpochFromUserDepositList(controller, i);
          // Adjust index and epochsToCheck since we removed an element
          i--;
          epochsToCheck--;
        }
      }
    }

    shares = totalShares;
    LibERC20._mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(_totalAssets(), s.totalSupply);
    return shares;
  }

  /**
   * @notice ERC7540 mint (claim from async request)
   * @dev Epoch-based with automatic FIFO processing
   * @dev Processes up to 50 epochs per call to prevent gas issues
   * @param shares The amount of shares to claim
   * @param receiver The address to receive the shares
   * @param controller The address that controls the request
   * @return assets The amount of assets used
   */
  function mint(
    uint256 shares,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 assets) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Process claims from oldest to newest epochs to get the required shares
    // Only process up to 50 epochs per call for gas efficiency
    uint256 remainingShares = shares;
    uint256 totalAssetsUsed = 0;

    uint256[] memory userEpochs = s.userDepositEpochs[controller];
    uint256 epochsToCheck = userEpochs.length > 50 ? 50 : userEpochs.length;

    for (uint256 i = 0; i < epochsToCheck && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableAssets = LibGenesisVault.calculateClaimableForEpoch(controller, epoch, true);
      if (claimableAssets == 0) continue;

      // Calculate how many shares we can get from this epoch
      uint256 epochShares = (claimableAssets * (10 ** s.decimals)) / roundData.sharePrice;
      uint256 sharesToProcess = Math.min(remainingShares, epochShares);

      if (sharesToProcess > 0) {
        // Calculate assets needed for these shares using epoch-specific price
        uint256 assetsNeeded = (sharesToProcess * roundData.sharePrice) / (10 ** s.decimals);
        
        // SECURITY: Minimum first deposit check (donation attack prevention)
        if (s.totalSupply == 0 && assetsNeeded < MINIMUM_FIRST_DEPOSIT) {
          revert("VaultCoreFacet: First deposit too small");
        }
        
        // SECURITY: Zero share prevention (donation attack prevention)
        // Skip this epoch instead of reverting to prevent griefing attack
        if (sharesToProcess == 0) {
          continue; // Skip to next epoch
        }
        
        totalAssetsUsed += assetsNeeded;

        // Update WAEP for the receiver with epoch-specific share price
        _updateUserWAEP(receiver, sharesToProcess, roundData.sharePrice);

        // Update global claimed amount
        roundData.claimedDepositAssets += assetsNeeded;

        // Update user-specific claimed amount
        s.userEpochClaimedDepositAssets[controller][epoch] += assetsNeeded;

        remainingShares -= sharesToProcess;

        // If this epoch is fully claimed, remove it from the list
        if (
          s.userEpochDepositAssets[controller][epoch] ==
          s.userEpochClaimedDepositAssets[controller][epoch]
        ) {
          _removeEpochFromUserDepositList(controller, i);
          // Adjust index and epochsToCheck since we removed an element
          i--;
          epochsToCheck--;
        }
      }
    }

    require(remainingShares == 0, "VaultCoreFacet: Insufficient claimable for shares");

    assets = totalAssetsUsed;
    LibERC20._mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(_totalAssets(), s.totalSupply);
    return assets;
  }

  // ============ ERC7540 Withdraw/Redeem (3-parameter) ============

  /**
   * @notice ERC7540 withdraw with Epoch-based calculation
   * @dev Processes up to 50 epochs per call to prevent gas issues
   * @param assets The amount of assets to withdraw
   * @param receiver The address to receive the assets
   * @param controller The address that controls the request
   * @return shares The amount of shares burned
   */
  function withdraw(
    uint256 assets,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 shares) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Calculate gross assets needed to get desired net assets after exit cost
    uint256 exitCostAmount = s.exitCost;
    uint256 grossAssetsNeeded = assets + exitCostAmount;

    // Epoch-based: Calculate total claimable across user's epochs
    uint256 totalClaimable = _calculateClaimableRedeemAssetsAcrossEpochs(controller);
    require(totalClaimable >= grossAssetsNeeded, "VaultCoreFacet: Insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    // Only process up to 50 epochs per call for gas efficiency
    uint256 remainingGrossAssets = grossAssetsNeeded;
    uint256 totalShares = 0;
    uint256 totalPerformanceFees = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[controller];
    uint256 epochsToCheck = userEpochs.length > 50 ? 50 : userEpochs.length;

    for (uint256 i = 0; i < epochsToCheck && remainingGrossAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableShares = LibGenesisVault.calculateClaimableForEpoch(
        controller,
        epoch,
        false
      );
      if (claimableShares == 0) continue;

      // Calculate assets available from this epoch
      uint256 epochAssets = (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
      uint256 assetsToProcess = Math.min(remainingGrossAssets, epochAssets);

      if (assetsToProcess > 0) {
        // Calculate shares needed using epoch-specific share price
        uint256 epochSharesNeeded = (assetsToProcess * (10 ** s.decimals)) / roundData.sharePrice;
        totalShares += epochSharesNeeded;

        // Calculate and charge performance fee for this withdrawal
        uint256 feeAmount = _calculateAndChargePerformanceFee(
          controller,
          epochSharesNeeded,
          roundData.sharePrice
        );
        totalPerformanceFees += feeAmount;

        // Update global claimed amount
        roundData.claimedRedeemShares += epochSharesNeeded;

        // Update user-specific claimed amount
        s.userEpochClaimedRedeemShares[controller][epoch] += epochSharesNeeded;

        remainingGrossAssets -= assetsToProcess;

        // If this epoch is fully claimed, remove it from the list
        if (
          s.userEpochRedeemShares[controller][epoch] ==
          s.userEpochClaimedRedeemShares[controller][epoch]
        ) {
          _removeEpochFromUserRedeemList(controller, i);
          // Adjust index and epochsToCheck since we removed an element
          i--;
          epochsToCheck--;
        }
      }
    }

    shares = totalShares;

    // Apply exit cost to gross assets
    LibGenesisVault.transferFeesToRecipient(exitCostAmount, "exit");

    // Final amount = gross assets - exit cost - performance fees
    uint256 finalAmount = grossAssetsNeeded - exitCostAmount - totalPerformanceFees;
    require(finalAmount >= assets, "VaultCoreFacet: Insufficient after fees");

    // Check vault balance before transfer
    uint256 currentBalance = s.asset.balanceOf(address(this));
    require(currentBalance >= assets, "VaultCoreFacet: Insufficient vault balance for withdraw");

    s.asset.safeTransfer(receiver, assets);

    emit Withdraw(msg.sender, receiver, controller, assets, shares);
    return shares;
  }

  /**
   * @notice ERC7540 redeem with Epoch-based calculation
   * @dev Processes up to 50 epochs per call to prevent gas issues
   * @param shares The amount of shares to redeem
   * @param receiver The address to receive the assets
   * @param controller The address that controls the request
   * @return assets The amount of assets withdrawn
   */
  function redeem(
    uint256 shares,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 assets) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();

    // Epoch-based: Calculate total claimable shares
    uint256 totalClaimableShares = _calculateClaimableRedeemSharesAcrossEpochs(controller);
    require(totalClaimableShares >= shares, "VaultCoreFacet: Insufficient claimable shares");

    // Process claims from oldest to newest epochs (FIFO)
    // Only process up to 50 epochs per call for gas efficiency
    uint256 remainingShares = shares;
    uint256 totalAssetsBeforeFees = 0;
    uint256 totalPerformanceFees = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[controller];
    uint256 epochsToCheck = userEpochs.length > 50 ? 50 : userEpochs.length;

    for (uint256 i = 0; i < epochsToCheck && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableShares = LibGenesisVault.calculateClaimableForEpoch(
        controller,
        epoch,
        false
      );
      uint256 sharesToProcess = Math.min(remainingShares, claimableShares);

      if (sharesToProcess > 0) {
        // Calculate assets from epoch-specific share price
        uint256 epochAssets = (sharesToProcess * roundData.sharePrice) / (10 ** s.decimals);
        totalAssetsBeforeFees += epochAssets;

        // Calculate and charge performance fee for this withdrawal
        uint256 feeAmount = _calculateAndChargePerformanceFee(
          controller,
          sharesToProcess,
          roundData.sharePrice
        );
        totalPerformanceFees += feeAmount;

        // Update global claimed amount
        roundData.claimedRedeemShares += sharesToProcess;

        // Update user-specific claimed amount
        s.userEpochClaimedRedeemShares[controller][epoch] += sharesToProcess;

        remainingShares -= sharesToProcess;

        // If this epoch is fully claimed, remove it from the list
        if (
          s.userEpochRedeemShares[controller][epoch] ==
          s.userEpochClaimedRedeemShares[controller][epoch]
        ) {
          _removeEpochFromUserRedeemList(controller, i);
          // Adjust index and epochsToCheck since we removed an element
          i--;
          epochsToCheck--;
        }
      }
    }

    // Apply exit cost
    uint256 exitCostAmount = s.exitCost;
    LibGenesisVault.transferFeesToRecipient(exitCostAmount, "exit");

    // Final assets = total - exit cost - performance fees
    assets = totalAssetsBeforeFees - exitCostAmount - totalPerformanceFees;

    // Check vault balance before transfer
    uint256 currentBalance = s.asset.balanceOf(address(this));
    require(currentBalance >= assets, "VaultCoreFacet: Insufficient vault balance for redeem");

    s.asset.safeTransfer(receiver, assets);

    emit Withdraw(msg.sender, receiver, controller, assets, shares);
    return assets;
  }

  // ============ 2-parameter versions (deprecated - revert) ============

  /**
   * @notice ERC4626 deposit - DEPRECATED, use requestDeposit instead
   */
  function deposit(uint256, address) external pure returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by deposit(assets, receiver, controller)");
  }

  /**
   * @notice ERC4626 mint - DEPRECATED, use requestDeposit instead
   */
  function mint(uint256, address) external pure returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by mint(shares, receiver, controller)");
  }

  // ============ Internal Helper Functions ============

  /**
   * @notice Calculate total claimable deposit assets across epochs
   * @dev Checks all user's deposit epochs (no time-based limit to prevent asset loss)
   */
  function _calculateClaimableDepositAssetsAcrossEpochs(
    address user
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userDepositEpochs[user];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      if (s.roundData[epoch].isSettled) {
        total += LibGenesisVault.calculateClaimableForEpoch(user, epoch, true);
      }
    }

    return total;
  }

  /**
   * @notice Calculate total claimable redeem shares across epochs
   * @dev Checks all user's redeem epochs (no time-based limit to prevent asset loss)
   */
  function _calculateClaimableRedeemSharesAcrossEpochs(
    address user
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[user];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      if (s.roundData[epoch].isSettled) {
        total += LibGenesisVault.calculateClaimableForEpoch(user, epoch, false);
      }
    }

    return total;
  }

  /**
   * @notice Calculate total claimable redeem assets across epochs
   * @dev Checks all user's redeem epochs (no time-based limit to prevent asset loss)
   */
  function _calculateClaimableRedeemAssetsAcrossEpochs(
    address user
  ) internal view returns (uint256) {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256 total = 0;

    uint256[] memory userEpochs = s.userRedeemEpochs[user];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];

      LibGenesisVaultStorage.RoundData storage roundData = s.roundData[epoch];
      if (roundData.isSettled) {
        uint256 claimableShares = LibGenesisVault.calculateClaimableForEpoch(user, epoch, false);
        total += (claimableShares * roundData.sharePrice) / (10 ** s.decimals);
      }
    }

    return total;
  }

  /**
   * @notice Get total assets
   * @dev Uses LibGenesisVault.totalAssets() which implements:
   *      (idleAssets + strategyAssets - totalClaimableWithdraw)
   */
  function _totalAssets() internal view returns (uint256) {
    return LibGenesisVault.totalAssets();
  }

  /**
   * @notice Update user WAEP (calls FeeManagementFacet)
   */
  function _updateUserWAEP(address user, uint256 newShares, uint256 currentSharePrice) internal {
    // This would delegatecall to FeeManagementFacet's updateUserWAEP
    // For Diamond pattern, we need to call it directly
    // Inline the logic here to avoid circular dependencies
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.UserPerformanceData storage userData = s.userPerformanceData[user];

    uint256 currentShares = s.balances[user]; // Shares before this deposit (called before _mint)

    if (currentShares == 0) {
      userData.waep = currentSharePrice;
    } else {
      // Weighted average calculation
      // WAEP_new = (WAEP_prev × shares_prev + sharePrice_current × shares_new) / (shares_prev + shares_new)
      userData.waep =
        (userData.waep * currentShares + currentSharePrice * newShares) /
        (currentShares + newShares);
    }

    userData.totalShares = currentShares + newShares;
    userData.lastUpdateEpoch = block.timestamp;
  }

  /**
   * @notice Calculate and charge performance fee (calls FeeManagementFacet logic)
   */
  function _calculateAndChargePerformanceFee(
    address user,
    uint256 withdrawShares,
    uint256 currentSharePrice
  ) internal returns (uint256 feeAmount) {
    // Inline the logic from FeeManagementFacet
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    LibGenesisVaultStorage.UserPerformanceData storage userData = s.userPerformanceData[user];

    if (userData.waep == 0) {
      userData.waep = currentSharePrice;
      return 0;
    }

    if (currentSharePrice > userData.waep) {
      uint256 profitPerShare = currentSharePrice - userData.waep;
      uint256 totalProfit = (profitPerShare * withdrawShares) / (10 ** s.decimals);

      uint256 hurdleRateValue = s.hurdleRate;
      if (hurdleRateValue > 0) {
        uint256 hurdleThresholdPerShare = (userData.waep * hurdleRateValue) / FLOAT_PRECISION;

        if (profitPerShare > hurdleThresholdPerShare) {
          uint256 excessProfitPerShare = profitPerShare - hurdleThresholdPerShare;
          uint256 excessProfit = (excessProfitPerShare * withdrawShares) / (10 ** s.decimals);
          feeAmount = (excessProfit * s.performanceFee) / FLOAT_PRECISION;
        }
      } else {
        feeAmount = (totalProfit * s.performanceFee) / FLOAT_PRECISION;
      }

      if (feeAmount > 0) {
        LibGenesisVault.transferFeesToRecipient(feeAmount, "performance");
        emit PerformanceFeeCharged(user, feeAmount, currentSharePrice, userData.waep);
      }
    }

    userData.totalShares = s.balances[user] - withdrawShares;
    return feeAmount;
  }

  /**
   * @notice Add user to epoch deposit list
   */
  function _addUserToEpochDepositList(address user, uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address[] storage users = s.epochDepositUsers[epoch];

    // Check if user already exists
    for (uint256 i = 0; i < users.length; i++) {
      if (users[i] == user) return;
    }

    users.push(user);
  }

  /**
   * @notice Add user to epoch redeem list
   */
  function _addUserToEpochRedeemList(address user, uint256 epoch) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    address[] storage users = s.epochRedeemUsers[epoch];

    // Check if user already exists
    for (uint256 i = 0; i < users.length; i++) {
      if (users[i] == user) return;
    }

    users.push(user);
  }

  /**
   * @notice Remove epoch from user's deposit epoch list
   * @dev Uses swap-and-pop for gas efficiency
   * @param user The user address
   * @param index The index of the epoch to remove
   */
  function _removeEpochFromUserDepositList(address user, uint256 index) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256[] storage epochs = s.userDepositEpochs[user];

    require(index < epochs.length, "VaultCoreFacet: Invalid index");

    // Swap with last element and pop
    epochs[index] = epochs[epochs.length - 1];
    epochs.pop();
  }

  /**
   * @notice Remove epoch from user's redeem epoch list
   * @dev Uses swap-and-pop for gas efficiency
   * @param user The user address
   * @param index The index of the epoch to remove
   */
  function _removeEpochFromUserRedeemList(address user, uint256 index) internal {
    LibGenesisVaultStorage.Layout storage s = LibGenesisVaultStorage.layout();
    uint256[] storage epochs = s.userRedeemEpochs[user];

    require(index < epochs.length, "VaultCoreFacet: Invalid index");

    // Swap with last element and pop
    epochs[index] = epochs[epochs.length - 1];
    epochs.pop();
  }
}
