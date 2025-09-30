// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { GenesisManagedVault } from "./GenesisManagedVault.sol";
import { GenesisVaultStorage } from "./storage/GenesisVaultStorage.sol";
import { IGenesisVaultErrors } from "./errors/GenesisVaultErrors.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";
import { IERC7540 } from "./interfaces/IERC7540.sol";

// Interface for BaseVol contract
interface IBaseVol {
  function currentEpoch() external view returns (uint256);
}

contract GenesisVault is Initializable, GenesisManagedVault, IERC7540 {
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  uint256 constant MAX_COST = 0.10 ether; // 10%

  event Shutdown(address account);
  event StrategyUpdated(address account, address newStrategy);
  event EntryCostUpdated(address account, uint256 newEntryCost);
  event ExitCostUpdated(address account, uint256 newExitCost);
  event MaxCostsUpdated(address account, uint256 newMaxEntryCost, uint256 newMaxExitCost);
  event PriorityProviderUpdated(address account, address newPriorityProvider);
  event VaultState(uint256 indexed totalAssets, uint256 indexed totalSupply);
  event PrioritizedAccountAdded(address indexed account);
  event PrioritizedAccountRemoved(address indexed account);

  // Epoch-based events
  event EpochSettled(uint256 indexed epoch, uint256 sharePrice);
  event DepositFromEpoch(
    address indexed controller,
    address indexed receiver,
    uint256 indexed epoch,
    uint256 assets,
    uint256 shares,
    uint256 sharePrice
  );
  event RedeemFromEpoch(
    address indexed controller,
    address indexed receiver,
    uint256 indexed epoch,
    uint256 shares,
    uint256 assets,
    uint256 sharePrice
  );
  event BatchDeposit(
    address indexed controller,
    address indexed receiver,
    uint256[] epochs,
    uint256[] amounts,
    uint256 totalShares
  );

  // Fee-related events
  event FeesWithdrawn(address indexed to, uint256 amount);

  // ERC7540 Events (use OpenZeppelin's Withdraw/Redeem events)

  function initialize(
    address baseVolContract_,
    address asset_,
    uint256 entryCost_,
    uint256 exitCost_,
    string calldata name_,
    string calldata symbol_
  ) external initializer {
    __GenesisManagedVault_init(msg.sender, msg.sender, asset_, name_, symbol_);
    require(entryCost_ <= MAX_COST, "Entry cost too high");
    require(exitCost_ <= MAX_COST, "Exit cost too high");

    _setEntryCost(entryCost_);
    _setExitCost(exitCost_);

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.baseVolContract = baseVolContract_;
  }

  /*//////////////////////////////////////////////////////////////
                            ERC165 SUPPORT
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC165 interface support
  function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return
      interfaceId == type(IERC7540).interfaceId ||
      interfaceId == type(IERC4626).interfaceId ||
      interfaceId == type(IERC20).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /*//////////////////////////////////////////////////////////////
                        BASEVOL INTEGRATION FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

  /// @notice Get current epoch from BaseVol system in real-time
  function getCurrentEpoch() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address baseVolContract = $.baseVolContract;

    // If BaseVol contract is not set, fallback to stored epoch
    if (baseVolContract == address(0)) {
      revert BaseVolContractNotSet();
    }

    // Call BaseVol contract to get real-time current epoch
    try IBaseVol(baseVolContract).currentEpoch() returns (uint256 currentEpoch) {
      return currentEpoch;
    } catch {
      return 0;
    }
  }

  /// @notice Called by BaseVol contract when an epoch is settled
  /// @param epoch The epoch number that was settled
  function onEpochSettled(uint256 epoch) external {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    require(msg.sender == $.baseVolContract, "GenesisVault: unauthorized");

    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

    // Calculate share price based on vault's current state
    uint256 sharePrice = _calculateEpochSharePrice(epoch);

    epochData.sharePrice = sharePrice;
    epochData.isSettled = true;
    epochData.settlementTimestamp = block.timestamp;

    // When isSettled = true, all requests in this epoch become immediately claimable
    // No need for separate processing steps since everything is processed atomically

    emit EpochSettled(epoch, sharePrice);
  }

  /// @notice Set BaseVol contract address (only owner)
  function setBaseVolContract(address _baseVolContract) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.baseVolContract = _baseVolContract;
  }

  /// @notice Configures the strategy.
  /// Note:
  /// - Approve new strategy to manage asset of this vault infinitely.
  /// - If there is an old strategy, revoke its asset approval after stopping the strategy.
  function setStrategy(address _strategy) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    IERC20 _asset = IERC20(asset());
    address prevStrategy = strategy();

    if (prevStrategy != address(0)) {
      IGenesisStrategy(prevStrategy).stop();
      _asset.approve(prevStrategy, 0);
    }

    require(_strategy != address(0));
    if (
      IGenesisStrategy(_strategy).asset() != address(_asset) ||
      IGenesisStrategy(_strategy).vault() != address(this)
    ) {
      revert InvalidStrategy();
    }

    $.strategy = _strategy;
    _asset.approve(_strategy, type(uint256).max);

    emit StrategyUpdated(_msgSender(), _strategy);
  }

  /// @notice Configures new entry/exit cost setting.
  function setEntryAndExitCost(uint256 newEntryCost, uint256 newExitCost) external onlyAdmin {
    _setEntryCost(newEntryCost);
    _setExitCost(newExitCost);
  }

  /// @notice Adds a prioritized account (only admin can call)
  function addPrioritizedAccount(address account) external onlyAdmin {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    // Check if already exists
    for (uint256 i = 0; i < $.prioritizedAccounts.length; i++) {
      if ($.prioritizedAccounts[i] == account) {
        revert AccountAlreadyPrioritized();
      }
    }
    $.prioritizedAccounts.push(account);
    emit PrioritizedAccountAdded(account);
  }

  /// @notice Removes a prioritized account (only admin can call)
  function removePrioritizedAccount(address account) external onlyAdmin {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 length = $.prioritizedAccounts.length;
    for (uint256 i = 0; i < length; i++) {
      if ($.prioritizedAccounts[i] == account) {
        // Move last element to current position and pop
        $.prioritizedAccounts[i] = $.prioritizedAccounts[length - 1];
        $.prioritizedAccounts.pop();
        emit PrioritizedAccountRemoved(account);
        return;
      }
    }
    revert AccountNotPrioritized();
  }

  /// @notice Shutdown vault, where all deposit/mint are disabled while withdraw/redeem are still available.
  function shutdown() external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.shutdown = true;
    IGenesisStrategy(strategy()).stop();
    emit Shutdown(_msgSender());
  }

  /// @notice Pauses Vault temporarily so that deposit and withdraw functions are disabled.
  /// This function is callable only by the admin
  /// and is used if some unexpected behaviors from external protocols are spotted
  /// by the admin.
  ///
  /// @param stopStrategy True means stopping strategy, otherwise pausing strategy.
  function pause(bool stopStrategy) external onlyAdmin whenNotPaused {
    if (stopStrategy) {
      IGenesisStrategy(strategy()).stop();
    } else {
      IGenesisStrategy(strategy()).pause();
    }
    _pause();
  }

  /// @dev Unpauses Vault so that deposit and withdraw functions are enabled again.
  /// This function is callable only by the admin.
  function unpause() external onlyAdmin whenPaused {
    IGenesisStrategy(strategy()).unpause();
    _unpause();
  }

  /// @notice Sweep vault when nothing is happening.
  ///
  /// @param receiver The address who will receive idle assets.
  function sweep(address receiver) external onlyOwner {
    // 1. all shares should be redeemed.
    // 2. utilized assets should be zero that means all requests have been processed.
    // 3. All assets should be withdrawn from strategy and no pending requests should remain.
    require(
      totalSupply() == 0 &&
        IGenesisStrategy(strategy()).utilizedAssets() == 0 &&
        totalPendingWithdraw() == 0
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: sweep ERC7540 pending states if needed
    // Note: In normal operation, these should already be zero

    // sweep prioritized accounts array
    delete $.prioritizedAccounts;

    // sweep idle assets
    IERC20(asset()).safeTransfer(receiver, idleAssets());
  }

  function harvestPerformanceFee() external {
    if (_msgSender() != strategy()) {
      revert CallerNotStrategy();
    }
    _harvestPerformanceFeeShares();
  }

  /// @notice Withdraw accumulated fees (only admin)
  /// @param to Address to receive the fees
  /// @param amount Amount of fees to withdraw (0 = all)
  function withdrawFees(address to, uint256 amount) external onlyAdmin {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 availableFees = $.accumulatedFees;
    require(availableFees > 0, "GenesisVault: no fees available");
    require(to != address(0), "GenesisVault: invalid recipient");

    uint256 withdrawAmount = amount == 0 ? availableFees : amount;
    require(withdrawAmount <= availableFees, "GenesisVault: insufficient fees");

    $.accumulatedFees -= withdrawAmount;
    IERC20(asset()).safeTransfer(to, withdrawAmount);

    emit FeesWithdrawn(to, withdrawAmount);
  }

  /*//////////////////////////////////////////////////////////////
                          ERC7540 OPERATOR SYSTEM
    //////////////////////////////////////////////////////////////*/

  /// @notice Set or unset an operator for the caller
  /// @param operator The address to set as operator
  /// @param approved Whether to approve or revoke the operator
  /// @return success Whether the operation was successful
  function setOperator(address operator, bool approved) external override returns (bool) {
    GenesisVaultStorage.layout().operators[_msgSender()][operator] = approved;
    emit OperatorSet(_msgSender(), operator, approved);
    return true;
  }

  /// @notice Check if an address is an operator for a controller
  /// @param controller The address that owns the requests
  /// @param operator The address to check for operator status
  /// @return Whether the operator is approved
  function isOperator(address controller, address operator) external view override returns (bool) {
    return GenesisVaultStorage.layout().operators[controller][operator];
  }

  /// @dev Modifier for operator access control
  modifier onlyControllerOrOperator(address controller) {
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );
    _;
  }

  /*//////////////////////////////////////////////////////////////
                          ERC7540 ASYNC DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Submit a request for asynchronous deposit
  /// @param assets The amount of assets to deposit
  /// @param controller The address that will control the request
  /// @param owner The address that owns the assets
  /// @return requestId The ID of the request
  function requestDeposit(
    uint256 assets,
    address controller,
    address owner
  ) external override returns (uint256 requestId) {
    require(assets > 0, "GenesisVault: zero assets");
    require(!paused() && !isShutdown(), "GenesisVault: vault not active");

    // ERC7540: owner MUST equal msg.sender unless owner has approved msg.sender as operator
    require(
      _msgSender() == owner || GenesisVaultStorage.layout().operators[owner][_msgSender()],
      "GenesisVault: not authorized"
    );

    // Essential: Validate against deposit limits
    uint256 maxDepositAmount = maxDeposit(owner);
    require(assets <= maxDepositAmount, "GenesisVault: deposit exceeds limit");

    // Transfer assets to vault
    IERC20(asset()).safeTransferFrom(owner, address(this), assets);

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Apply entry cost - only the net amount after fee goes to investment
    uint256 entryCostAmount = _costOnTotal(assets, entryCost());
    uint256 netAssets = assets - entryCostAmount;

    // Track accumulated fees
    $.accumulatedFees += entryCostAmount;

    // Get current epoch from BaseVol system
    uint256 currentEpoch = getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking with net assets (after fee)
    $.userEpochDepositAssets[controller][currentEpoch] += netAssets;
    $.epochData[currentEpoch].totalRequestedDepositAssets += netAssets;

    // Add to user's epoch list (avoid duplicates)
    if ($.userEpochDepositAssets[controller][currentEpoch] == netAssets) {
      $.userDepositEpochs[controller].push(currentEpoch);
    }

    emit DepositRequest(controller, owner, requestId, _msgSender(), assets);

    return requestId;
  }

  /// @notice Returns the amount of requested assets in Pending state for the controller with the given requestId to deposit or mint
  /// @param requestId The ID of the request
  /// @param controller The address to check
  /// @return assets The amount of pending deposit assets
  function pendingDepositRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Claimable state for deposit
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];
    if (epochData.isSettled) {
      return 0; // Assets are in claimable state, not pending
    }

    // Return the pending assets for this controller in this epoch
    return $.userEpochDepositAssets[controller][epoch];
  }

  /// @notice Returns the amount of requested assets in Claimable state for the controller with the given requestId to deposit or mint
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return assets The amount of claimable deposit assets
  function claimableDepositRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Pending state for deposit
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];
    if (!epochData.isSettled) {
      return 0; // Assets are still in pending state, not claimable
    }

    // Calculate claimable assets for this specific epoch
    return _calculateClaimableForEpoch(controller, epoch, true);
  }

  /*//////////////////////////////////////////////////////////////
                          ASYNC WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Returns the maximum amount of the underlying asset that can be
  /// requested to withdraw from the owner balance in the Vault,
  /// through a requestRedeem call (ERC7540 uses requestRedeem for both)
  function maxRequestWithdraw(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Return max assets based on owner's shares (for redeem requests)
    uint256 shares = balanceOf(owner);
    return _convertToAssets(shares, Math.Rounding.Floor);
  }

  /// @notice Returns the maximum amount of Vault shares that can be
  /// requested to redeem from the owner balance in the Vault,
  /// through a requestRedeem call.
  function maxRequestRedeem(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Return owner's share balance for redeem requests
    return balanceOf(owner);
  }

  /// @notice ERC7540 - Returns max assets for requestDeposit (same as maxDeposit)
  function maxRequestDeposit(address owner) public view returns (uint256) {
    return maxDeposit(owner);
  }

  /// @notice ERC7540 - Returns max assets for immediate withdraw (claimable only) using Epoch-based calculation
  function maxClaimableWithdraw(address controller) public view returns (uint256) {
    return _calculateClaimableRedeemAssetsAcrossEpochs(controller);
  }

  /// @notice ERC7540 - Returns max shares for immediate redeem (claimable only) using Epoch-based calculation
  function maxClaimableRedeem(address controller) public view returns (uint256) {
    return _calculateClaimableRedeemSharesAcrossEpochs(controller);
  }

  function _setEntryCost(uint256 value) internal {
    require(value <= MAX_COST, "Entry cost exceeds maximum");
    if (entryCost() != value) {
      GenesisVaultStorage.layout().entryCost = value;
      emit EntryCostUpdated(_msgSender(), value);
    }
  }

  function _setExitCost(uint256 value) internal {
    require(value <= MAX_COST, "Exit cost exceeds maximum");
    if (exitCost() != value) {
      GenesisVaultStorage.layout().exitCost = value;
      emit ExitCostUpdated(_msgSender(), value);
    }
  }

  /// @notice ERC7540 redeem request with priority support
  /// @param shares The amount of shares to redeem
  /// @param controller The address that will control the request
  /// @param owner The address that owns the shares
  /// @return requestId The ID of the request
  function requestRedeem(
    uint256 shares,
    address controller,
    address owner
  ) external override returns (uint256 requestId) {
    require(shares > 0, "GenesisVault: zero shares");
    require(!paused() && !isShutdown(), "GenesisVault: vault not active");

    // ERC7540: Redeem Request approval may come from ERC-20 approval OR operator approval
    if (_msgSender() != owner) {
      bool hasOperatorApproval = GenesisVaultStorage.layout().operators[owner][_msgSender()];
      if (!hasOperatorApproval) {
        _spendAllowance(owner, _msgSender(), shares);
      }
      // Note: If operator, no allowance deduction per ERC7540 spec
    }
    _burn(owner, shares);

    // Check priority status
    bool isPrioritizedAccount = isPrioritized(owner);

    // Create request
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Get current epoch from BaseVol system
    uint256 currentEpoch = getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking
    $.userEpochRedeemShares[controller][currentEpoch] += shares;
    $.epochData[currentEpoch].totalRequestedRedeemShares += shares;

    // Add to user's epoch list (avoid duplicates)
    if ($.userEpochRedeemShares[controller][currentEpoch] == shares) {
      $.userRedeemEpochs[controller].push(currentEpoch);
    }

    emit RedeemRequest(controller, owner, requestId, _msgSender(), shares);

    return requestId;
  }

  /// @notice Returns the amount of requested shares in Pending state for the controller with the given requestId to redeem
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return shares The amount of pending redemption shares
  function pendingRedeemRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Claimable state for redeem
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];
    if (epochData.isSettled) {
      return 0; // Shares are in claimable state, not pending
    }

    // Return the pending shares for this controller in this epoch
    return $.userEpochRedeemShares[controller][epoch];
  }

  /// @notice Returns the amount of requested shares in Claimable state for the controller with the given requestId to redeem
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return shares The amount of claimable redemption shares
  function claimableRedeemRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Pending state for redeem
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];
    if (!epochData.isSettled) {
      return 0; // Shares are still in pending state, not claimable
    }

    // Calculate claimable shares for this specific epoch
    return _calculateClaimableForEpoch(controller, epoch, false);
  }

  /// @notice Tells if the owner is prioritized to withdraw.
  function isPrioritized(address owner) public view returns (bool) {
    address[] memory _prioritizedAccounts = prioritizedAccounts();
    for (uint256 i = 0; i < _prioritizedAccounts.length; i++) {
      if (_prioritizedAccounts[i] == owner) {
        return true;
      }
    }
    return false;
  }

  /// @notice The underlying asset amount in this vault that is free to withdraw or utilize.
  /// @dev Excludes accumulated fees which are reserved for withdrawal by owner
  function idleAssets() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalBalance = IERC20(asset()).balanceOf(address(this));
    uint256 fees = $.accumulatedFees;

    // Return total balance minus accumulated fees
    return totalBalance > fees ? totalBalance - fees : 0;
  }

  /// @notice ERC7540 - Returns total pending redeem assets across all unsettled epochs
  /// @dev For ERC4626 compatibility - represents future obligations not yet settled
  function totalPendingWithdraw() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalPending = 0;

    // Sum up pending withdrawals across all users and epochs
    // Note: This is an approximation for compatibility. In practice,
    // we should track this more efficiently or calculate it differently.
    uint256 currentEpoch = getCurrentEpoch();

    // Check recent epochs (last 10) for pending redemptions
    for (uint256 i = 0; i < 10 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled && epochData.totalRequestedRedeemShares > 0) {
        // Convert shares to approximate assets using current share price
        totalPending += _convertToAssets(epochData.totalRequestedRedeemShares, Math.Rounding.Floor);
      }
    }

    return totalPending;
  }

  /// @notice Returns total claimable redeem assets across all settled epochs
  /// @dev This represents assets that users can immediately claim and Strategy needs to prepare for withdrawal
  function totalClaimableWithdraw() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;

    // Check broader range of epochs with claimable redemptions
    uint256 currentEpoch = getCurrentEpoch();

    // Check last 50 epochs to cover longer settlement periods
    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      // Only count settled epochs (claimable state)
      if (epochData.isSettled) {
        uint256 requested = epochData.totalRequestedRedeemShares;
        uint256 claimed = epochData.claimedRedeemShares;
        uint256 claimableShares = requested > claimed ? requested - claimed : 0;

        if (claimableShares > 0) {
          // Use epoch-specific share price for accurate calculation
          uint256 claimableAssets = (claimableShares * epochData.sharePrice) / (10 ** decimals());
          totalClaimable += claimableAssets;
        }
      }
    }

    return totalClaimable;
  }

  /*//////////////////////////////////////////////////////////////
                        EPOCH-SPECIFIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Deposit from a specific epoch using epoch-specific share price
  /// @param epoch The epoch to claim from
  /// @param assets The amount of assets to claim
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the request
  /// @return shares The amount of shares minted
  function depositFromEpoch(
    uint256 epoch,
    uint256 assets,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

    require(epochData.isSettled, "GenesisVault: epoch not ready");

    // Calculate claimable assets for this specific epoch
    uint256 claimableAssets = _calculateClaimableForEpoch(controller, epoch, true);
    require(claimableAssets >= assets, "GenesisVault: insufficient claimable assets");

    // Use epoch-specific share price
    shares = (assets * (10 ** decimals())) / epochData.sharePrice;

    // Update global claimed amount
    epochData.claimedDepositAssets += assets;

    // Update user-specific claimed amount
    $.userEpochClaimedDepositAssets[controller][epoch] += assets;

    _mint(receiver, shares);
    emit DepositFromEpoch(controller, receiver, epoch, assets, shares, epochData.sharePrice);
    return shares;
  }

  /// @notice Redeem from a specific epoch using epoch-specific share price
  /// @param epoch The epoch to claim from
  /// @param shares The amount of shares to redeem
  /// @param receiver The address to receive the assets
  /// @param controller The address that controls the request
  /// @return assets The amount of assets transferred
  function redeemFromEpoch(
    uint256 epoch,
    uint256 shares,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

    require(epochData.isSettled, "GenesisVault: epoch not ready");

    // Calculate claimable shares for this specific epoch
    uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
    require(claimableShares >= shares, "GenesisVault: insufficient claimable shares");

    // Use epoch-specific share price
    uint256 grossAssets = (shares * epochData.sharePrice) / (10 ** decimals());

    // Apply exit cost - user receives net amount after fee deduction
    uint256 exitCostAmount = _costOnTotal(grossAssets, exitCost());
    assets = grossAssets - exitCostAmount;

    // Track accumulated fees
    $.accumulatedFees += exitCostAmount;

    // Update global claimed amount
    epochData.claimedRedeemShares += shares;

    // Update user-specific claimed amount
    $.userEpochClaimedRedeemShares[controller][epoch] += shares;

    IERC20(asset()).safeTransfer(receiver, assets);
    emit RedeemFromEpoch(controller, receiver, epoch, shares, assets, epochData.sharePrice);
    return assets;
  }

  /// @notice Batch deposit from multiple epochs
  /// @param epochs Array of epochs to claim from
  /// @param amounts Array of asset amounts to claim from each epoch
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the requests
  /// @return totalShares The total amount of shares minted
  function batchDepositFromEpochs(
    uint256[] calldata epochs,
    uint256[] calldata amounts,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 totalShares) {
    require(epochs.length == amounts.length, "GenesisVault: array length mismatch");

    for (uint256 i = 0; i < epochs.length; i++) {
      if (amounts[i] > 0) {
        totalShares += this.depositFromEpoch(epochs[i], amounts[i], receiver, controller);
      }
    }

    emit BatchDeposit(controller, receiver, epochs, amounts, totalShares);
    return totalShares;
  }

  /*//////////////////////////////////////////////////////////////
                             ERC7540 CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC7540 deposit (claim from async request) - Epoch-based with automatic FIFO processing
  /// @param assets The amount of assets to claim
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the request
  /// @return shares The amount of shares minted
  function deposit(
    uint256 assets,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableDepositAssetsAcrossEpochs(controller);
    require(totalClaimable >= assets, "GenesisVault: insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingAssets = assets;
    uint256 totalShares = 0;

    uint256[] memory userEpochs = $.userDepositEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled) continue;

      uint256 claimableAssets = _calculateClaimableForEpoch(controller, epoch, true);
      uint256 assetsToProcess = Math.min(remainingAssets, claimableAssets);

      if (assetsToProcess > 0) {
        // Use epoch-specific share price
        // shares = assets * (10^shareDecimals) / sharePrice
        uint256 epochShares = (assetsToProcess * (10 ** decimals())) / epochData.sharePrice;
        totalShares += epochShares;

        // Update global claimed amount
        epochData.claimedDepositAssets += assetsToProcess;

        // Update user-specific claimed amount
        $.userEpochClaimedDepositAssets[controller][epoch] += assetsToProcess;

        remainingAssets -= assetsToProcess;
      }
    }

    shares = totalShares;
    _mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return shares;
  }

  /// @notice ERC7540 mint (claim from async request) - Epoch-based with automatic FIFO processing
  /// @param shares The amount of shares to claim
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the request
  /// @return assets The amount of assets used
  function mint(
    uint256 shares,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Process claims from oldest to newest epochs to get the required shares
    uint256 remainingShares = shares;
    uint256 totalAssetsUsed = 0;

    uint256[] memory userEpochs = $.userDepositEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled) continue;

      uint256 claimableAssets = _calculateClaimableForEpoch(controller, epoch, true);
      if (claimableAssets == 0) continue;

      // Calculate how many shares we can get from this epoch
      uint256 epochShares = (claimableAssets * (10 ** decimals())) / epochData.sharePrice;
      uint256 sharesToProcess = Math.min(remainingShares, epochShares);

      if (sharesToProcess > 0) {
        // Calculate assets needed for these shares using epoch-specific price
        uint256 assetsNeeded = (sharesToProcess * epochData.sharePrice) / (10 ** decimals());
        totalAssetsUsed += assetsNeeded;

        // Update global claimed amount
        epochData.claimedDepositAssets += assetsNeeded;

        // Update user-specific claimed amount
        $.userEpochClaimedDepositAssets[controller][epoch] += assetsNeeded;

        remainingShares -= sharesToProcess;
      }
    }

    require(remainingShares == 0, "GenesisVault: insufficient claimable for shares");

    assets = totalAssetsUsed;
    _mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return assets;
  }

  /// @notice ERC7540 withdraw with Epoch-based calculation
  function withdraw(
    uint256 assets,
    address receiver,
    address controller
  ) public override(ERC4626Upgradeable, IERC7540) returns (uint256 shares) {
    //  ERC7540: controller MUST be msg.sender unless controller has approved msg.sender as operator
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Calculate gross assets needed to get desired net assets after exit cost
    // net = gross - (gross * exitCost / FLOAT_PRECISION)
    // net = gross * (1 - exitCost / FLOAT_PRECISION)
    // gross = net / (1 - exitCost / FLOAT_PRECISION)
    uint256 exitCostRate = exitCost();
    uint256 grossAssetsNeeded;
    if (exitCostRate > 0) {
      grossAssetsNeeded = (assets * FLOAT_PRECISION) / (FLOAT_PRECISION - exitCostRate);
    } else {
      grossAssetsNeeded = assets;
    }

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableRedeemAssetsAcrossEpochs(controller);
    require(totalClaimable >= grossAssetsNeeded, "GenesisVault: insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingGrossAssets = grossAssetsNeeded;
    uint256 totalShares = 0;

    uint256[] memory userEpochs = $.userRedeemEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingGrossAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled) continue;

      uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
      if (claimableShares == 0) continue;

      // Calculate assets available from this epoch
      uint256 epochAssets = (claimableShares * epochData.sharePrice) / (10 ** decimals());
      uint256 assetsToProcess = Math.min(remainingGrossAssets, epochAssets);

      if (assetsToProcess > 0) {
        // Calculate shares needed using epoch-specific share price
        uint256 epochSharesNeeded = (assetsToProcess * (10 ** decimals())) / epochData.sharePrice;
        totalShares += epochSharesNeeded;

        // Update global claimed amount
        epochData.claimedRedeemShares += epochSharesNeeded;

        // Update user-specific claimed amount
        $.userEpochClaimedRedeemShares[controller][epoch] += epochSharesNeeded;

        remainingGrossAssets -= assetsToProcess;
      }
    }

    shares = totalShares;
    IERC20(asset()).safeTransfer(receiver, assets);

    emit Withdraw(_msgSender(), receiver, controller, assets, shares);
    return shares;
  }

  /// @notice ERC7540 redeem with Epoch-based calculation
  function redeem(
    uint256 shares,
    address receiver,
    address controller
  ) public override(ERC4626Upgradeable, IERC7540) returns (uint256 assets) {
    //  ERC7540: controller MUST be msg.sender unless controller has approved msg.sender as operator
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableRedeemSharesAcrossEpochs(controller);
    require(totalClaimable >= shares, "GenesisVault: insufficient claimable shares");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingShares = shares;
    uint256 totalAssetsRedeemed = 0;

    uint256[] memory userEpochs = $.userRedeemEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled) continue;

      uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
      uint256 sharesToProcess = Math.min(remainingShares, claimableShares);

      if (sharesToProcess > 0) {
        // Use epoch-specific share price
        uint256 epochAssets = (sharesToProcess * epochData.sharePrice) / (10 ** decimals());
        totalAssetsRedeemed += epochAssets;

        // Update global claimed amount
        epochData.claimedRedeemShares += sharesToProcess;

        // Update user-specific claimed amount
        $.userEpochClaimedRedeemShares[controller][epoch] += sharesToProcess;

        remainingShares -= sharesToProcess;
      }
    }

    // Apply exit cost - user receives net amount after fee deduction
    uint256 exitCostAmount = _costOnTotal(totalAssetsRedeemed, exitCost());
    assets = totalAssetsRedeemed - exitCostAmount;

    // Track accumulated fees
    $.accumulatedFees += exitCostAmount;

    IERC20(asset()).safeTransfer(receiver, assets);

    emit Withdraw(_msgSender(), receiver, controller, assets, shares);
    return assets;
  }

  /*//////////////////////////////////////////////////////////////
                        ERC4626 FUNCTIONS (ERC7540 IMPLEMENTATION)
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC4626 deposit - DEPRECATED, use requestDeposit instead
  /// @dev Reserve the execution cost not to affect other's share price.
  function deposit(
    uint256 /* assets */,
    address /* receiver */
  ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by deposit(assets, receiver, controller)");
  }

  /// @notice ERC4626 mint - DEPRECATED, use requestDeposit instead
  function mint(
    uint256 /* shares */,
    address /* receiver */
  ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by mint(shares, receiver, controller)");
  }

  /// @inheritdoc ERC4626Upgradeable
  function totalAssets()
    public
    view
    virtual
    override(ERC4626Upgradeable, IERC4626)
    returns (uint256 assets)
  {
    // Only subtract confirmed obligations (claimable), not pending (unconfirmed) obligations
    // Pending withdraws use current share price which is inaccurate for unsettled epochs
    (, assets) = (idleAssets() + IGenesisStrategy(strategy()).utilizedAssets()).trySub(
      totalClaimableWithdraw()
    );
    return assets;
  }

  /// @notice ERC7540 - previewDeposit MUST revert for async vaults
  /// @inheritdoc ERC4626Upgradeable
  function previewDeposit(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    assets; // silence unused parameter warning
    revert("ERC7540: previewDeposit not supported for async vaults");
  }

  /// @notice ERC7540 - previewMint MUST revert for async vaults
  /// @inheritdoc ERC4626Upgradeable
  function previewMint(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    shares; // silence unused parameter warning
    revert("ERC7540: previewMint not supported for async vaults");
  }

  /// @notice ERC7540 - previewWithdraw MUST revert for async vaults
  function previewWithdraw(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    assets; // silence unused parameter warning
    revert("ERC7540: previewWithdraw not supported for async vaults");
  }

  /// @notice ERC7540 - previewRedeem MUST revert for async vaults
  function previewRedeem(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    shares; // silence unused parameter warning
    revert("ERC7540: previewRedeem not supported for async vaults");
  }

  /// @notice ERC7540 - maxDeposit returns max assets for requestDeposit
  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(
    address receiver
  ) public view virtual override(GenesisManagedVault, IERC4626) returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // ERC7540: Return max assets that can be requested for deposit
    // This represents the maximum amount for requestDeposit, not immediate deposit
    uint256 maxCapacity = _calculateMaxDepositRequest(receiver);
    return maxCapacity;
  }

  /// @notice Calculate maximum assets that can be requested for deposit
  function _calculateMaxDepositRequest(address receiver) internal view returns (uint256) {
    // TODO: Adjust this to use epoch-based data

    uint256 _userDepositLimit = userDepositLimit();
    uint256 _vaultDepositLimit = vaultDepositLimit();

    // If both limits are max, no restriction
    if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    }

    // Calculate user's current assets (including pending deposits)
    uint256 userShares = balanceOf(receiver);
    uint256 userCurrentAssets = _convertToAssets(userShares, Math.Rounding.Floor);

    // Add any pending deposit assets for this user (across all unsettled epochs)
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 userPendingAssets = 0;
    uint256[] memory userEpochs = $.userDepositEpochs[receiver];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      if (!$.epochData[epoch].isSettled) {
        userPendingAssets += $.userEpochDepositAssets[receiver][epoch];
      }
    }

    uint256 userTotalAssets = userCurrentAssets + userPendingAssets;

    // Calculate available user limit
    uint256 availableUserLimit = _userDepositLimit > userTotalAssets
      ? _userDepositLimit - userTotalAssets
      : 0;

    // Calculate available vault limit
    uint256 vaultCurrentAssets = totalAssets();
    uint256 availableVaultLimit = _vaultDepositLimit > vaultCurrentAssets
      ? _vaultDepositLimit - vaultCurrentAssets
      : 0;

    // Return the more restrictive limit
    return availableUserLimit < availableVaultLimit ? availableUserLimit : availableVaultLimit;
  }

  /// @notice ERC7540 - maxMint returns 0 since requestMint doesn't exist
  /// @inheritdoc ERC4626Upgradeable
  function maxMint(
    address /* receiver */
  ) public view virtual override(GenesisManagedVault, IERC4626) returns (uint256) {
    // ERC7540: mint() is deprecated and requestMint() doesn't exist
    // Therefore, no shares can be minted directly
    // Users should use requestDeposit() instead
    return 0;
  }

  /// @notice ERC7540 - maxWithdraw returns claimable assets using Epoch-based calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxWithdraw(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Epoch-based: Dynamic calculation of claimable assets across all epochs
    return _calculateClaimableRedeemAssetsAcrossEpochs(controller);
  }

  /// @notice ERC7540 - maxRedeem returns claimable shares using Epoch-based calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxRedeem(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Epoch-based: Dynamic calculation of claimable shares across all epochs
    return _calculateClaimableRedeemSharesAcrossEpochs(controller);
  }

  /// @dev If there are pending withdraw requests, the deposited assets is used to process them.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function _deposit(
    address caller,
    address receiver,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    if (shares == 0) {
      revert ZeroShares();
    }
    super._deposit(caller, receiver, assets, shares);
    // ERC7540: deposit processing is handled separately via processPendingDepositRequests()

    emit VaultState(totalAssets(), totalSupply());
  }

  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    super._withdraw(caller, receiver, owner, assets, shares);

    emit VaultState(totalAssets(), totalSupply());
  }

  /*//////////////////////////////////////////////////////////////
                        EPOCH-BASED HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Calculate claimable assets/shares for a specific epoch
  /// @param controller The controller address
  /// @param epoch The epoch to check
  /// @param isDeposit True for deposit assets, false for redeem shares
  /// @return claimable The amount claimable for this epoch
  function _calculateClaimableForEpoch(
    address controller,
    uint256 epoch,
    bool isDeposit
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

    if (!epochData.isSettled) return 0;

    if (isDeposit) {
      uint256 userTotal = $.userEpochDepositAssets[controller][epoch];
      uint256 userClaimed = $.userEpochClaimedDepositAssets[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    } else {
      uint256 userTotal = $.userEpochRedeemShares[controller][epoch];
      uint256 userClaimed = $.userEpochClaimedRedeemShares[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    }
  }

  /// @notice Calculate claimable deposit assets across all settled epochs
  function _calculateClaimableDepositAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userDepositEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (epochData.isSettled) {
        totalClaimable += _calculateClaimableForEpoch(controller, epoch, true);
      }
    }
    return totalClaimable;
  }

  /// @notice Calculate claimable redeem shares across all settled epochs
  function _calculateClaimableRedeemSharesAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (epochData.isSettled) {
        totalClaimable += _calculateClaimableForEpoch(controller, epoch, false);
      }
    }
    return totalClaimable;
  }

  /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Calculate share price for a specific epoch based on vault performance
  /// @param epoch The epoch to calculate share price for
  /// @return sharePrice The calculated share price (assets per share scaled by share decimals)
  function _calculateEpochSharePrice(uint256 epoch) internal view returns (uint256) {
    // If this is the first epoch or vault has no shares, use initial price
    if (totalSupply() == 0) {
      // Return 1 share worth 1 asset unit, scaled properly for decimals
      return 10 ** decimals(); // This handles the decimals offset correctly
    }

    // Get strategy performance data for this epoch
    address strategyAddress = strategy();
    if (strategyAddress == address(0)) {
      // No strategy deployed yet, return 1:1 ratio
      return 10 ** decimals();
    }

    // Calculate share price based on total vault value EXCLUDING pending deposits
    // This prevents pending deposits from inflating the share price before epoch settlement
    uint256 vaultTotalAssets = _totalAssetsForSharePrice();
    uint256 vaultTotalSupply = totalSupply();

    if (vaultTotalSupply == 0) {
      return 10 ** decimals();
    }

    // Share price = (total assets per share) scaled by share decimals
    // For proper decimals handling: assets * 10^shareDecimals / totalSupply
    return (vaultTotalAssets * (10 ** decimals())) / vaultTotalSupply;
  }

  /// @notice Calculate total assets for share price calculation (excluding pending deposits)
  /// @dev This prevents pending deposits from artificially inflating share price before settlement
  /// @return assets Total assets excluding pending deposits
  function _totalAssetsForSharePrice() internal view returns (uint256) {
    // Start with current strategy-controlled assets and claimable obligations
    address strategyAddress = strategy();
    uint256 strategyAssets = strategyAddress != address(0)
      ? IGenesisStrategy(strategyAddress).utilizedAssets()
      : 0;

    // Add only settled (non-pending) idle assets
    uint256 settledIdleAssets = _settledIdleAssets();

    // Subtract claimable withdrawals
    uint256 claimableWithdrawals = totalClaimableWithdraw();

    (, uint256 totalAssetsForPrice) = (settledIdleAssets + strategyAssets).trySub(
      claimableWithdrawals
    );
    return totalAssetsForPrice;
  }

  /// @notice Calculate idle assets excluding pending deposits
  /// @return assets Idle assets that have been settled and can be considered for share price
  function _settledIdleAssets() internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Get total vault balance
    uint256 totalBalance = IERC20(asset()).balanceOf(address(this));

    // Subtract accumulated fees
    uint256 fees = $.accumulatedFees;

    // Subtract total pending deposits (not yet settled)
    uint256 totalPendingDeposits = _totalPendingDeposits();

    // Return: total balance - fees - pending deposits
    uint256 grossSettledAssets = totalBalance > fees ? totalBalance - fees : 0;
    (, uint256 settledAssets) = grossSettledAssets.trySub(totalPendingDeposits);

    return settledAssets;
  }

  /// @notice Calculate total pending deposit assets across all unsettled epochs
  /// @return pendingAssets Total assets in pending state
  function _totalPendingDeposits() internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalPending = 0;
    uint256 currentEpoch = getCurrentEpoch();

    // Check recent epochs (last 10) for pending deposits
    for (uint256 i = 0; i < 10 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (!epochData.isSettled && epochData.totalRequestedDepositAssets > 0) {
        totalPending += epochData.totalRequestedDepositAssets;
      }
    }

    return totalPending;
  }

  /// @notice Calculate claimable redeem assets across all settled epochs (for legacy functions)
  function _calculateClaimableRedeemAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.EpochData storage epochData = $.epochData[epoch];

      if (epochData.isSettled) {
        uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
        // Convert shares to assets using epoch-specific share price
        totalClaimable += (claimableShares * epochData.sharePrice) / (10 ** decimals());
      }
    }
    return totalClaimable;
  }

  /// @dev Calculates the cost part of an amount `assets` that already includes cost.
  function _costOnTotal(uint256 assets, uint256 costRate) private pure returns (uint256) {
    return assets.mulDiv(costRate, costRate + FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

  /// @notice The address of strategy that uses the underlying asset of this vault.
  function strategy() public view returns (address) {
    return GenesisVaultStorage.layout().strategy;
  }

  /// @notice The prioritized accounts.
  /// For example, the addresses of logarithm meta vaults are prioritized to withdraw.
  /// Prioritizing of withdraw means that their withdraw requests are processed before the other normal withdraw requests.
  function prioritizedAccounts() public view returns (address[] memory) {
    return GenesisVaultStorage.layout().prioritizedAccounts;
  }

  /// @notice The entry cost percent that is charged when depositing.
  ///
  /// @dev Denominated in 18 decimals.
  function entryCost() public view returns (uint256) {
    return GenesisVaultStorage.layout().entryCost;
  }

  /// @notice The exit cost percent that is charged when withdrawing.
  ///
  /// @dev Denominated in 18 decimals.
  function exitCost() public view returns (uint256) {
    return GenesisVaultStorage.layout().exitCost;
  }

  /// @notice When this vault is shutdown, only withdrawals are available. It can't be reverted.
  function isShutdown() public view returns (bool) {
    return GenesisVaultStorage.layout().shutdown;
  }

  /// @notice Get accumulated fees
  function accumulatedFees() public view returns (uint256) {
    return GenesisVaultStorage.layout().accumulatedFees;
  }

  /// @notice The address of baseVol contract.
  function baseVolContract() public view returns (address) {
    return GenesisVaultStorage.layout().baseVolContract;
  }

  function epochData(uint256 epoch) public view returns (GenesisVaultStorage.EpochData memory) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    return $.epochData[epoch];
  }
}
