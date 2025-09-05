// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { GenesisManagedVault } from "./GenesisManagedVault.sol";
import { GenesisVaultStorage } from "./storage/GenesisVaultStorage.sol";
import { IGenesisVaultErrors } from "./errors/GenesisVaultErrors.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";

contract GenesisVault is Initializable, GenesisManagedVault {
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  uint256 constant MAX_COST = 0.10 ether; // 10%

  event WithdrawRequested(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    bytes32 withdrawKey,
    uint256 assets,
    uint256 shares
  );

  event Claimed(address indexed claimer, bytes32 withdrawKey, uint256 assets);
  event Shutdown(address account);
  event AdminUpdated(address indexed account, address indexed newAdmin);
  event StrategyUpdated(address account, address newStrategy);
  event EntryCostUpdated(address account, uint256 newEntryCost);
  event ExitCostUpdated(address account, uint256 newExitCost);
  event MaxCostsUpdated(address account, uint256 newMaxEntryCost, uint256 newMaxExitCost);
  event PriorityProviderUpdated(address account, address newPriorityProvider);
  event VaultState(uint256 indexed totalAssets, uint256 indexed totalSupply);
  event PrioritizedAccountAdded(address indexed account);
  event PrioritizedAccountRemoved(address indexed account);

  modifier onlyAdmin() {
    if (_msgSender() != admin()) {
      revert OnlyAdmin();
    }
    _;
  }

  function initialize(
    address asset_,
    uint256 entryCost_,
    uint256 exitCost_,
    string calldata name_,
    string calldata symbol_
  ) external initializer {
    __GenesisManagedVault_init(msg.sender, asset_, name_, symbol_);
    require(entryCost_ <= MAX_COST, "Entry cost too high");
    require(exitCost_ <= MAX_COST, "Exit cost too high");

    _setEntryCost(entryCost_);
    _setExitCost(exitCost_);
  }

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

  /// @notice Configures the admin.
  ///
  /// @param account The address of new admin.
  /// A zero address means disabling admin functions.
  function setAdmin(address account) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.admin = account;
    emit AdminUpdated(_msgSender(), account);
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

  /// @notice Adds a prioritized account (only owner can call)
  function addPrioritizedAccount(address account) external onlyOwner {
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

  /// @notice Removes a prioritized account (only owner can call)
  function removePrioritizedAccount(address account) external onlyOwner {
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
    // 3. assetsToClaim should be zero that means all requests have been claimed.
    require(
      totalSupply() == 0 &&
        IGenesisStrategy(strategy()).utilizedAssets() == 0 &&
        assetsToClaim() == 0
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // sweep pending states
    delete $.accRequestedWithdrawAssets;
    delete $.processedWithdrawAssets;

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

  /*//////////////////////////////////////////////////////////////
                          ASYNC WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Returns the maximum amount of the underlying asset that can be
  /// requested to withdraw from the owner balance in the Vault,
  /// through a requestWithdraw call.
  function maxRequestWithdraw(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    return super.maxWithdraw(owner);
  }

  /// @notice Returns the maximum amount of Vault shares that can be
  /// requested to redeem from the owner balance in the Vault,
  /// through a requestRedeem call.
  function maxRequestRedeem(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    return super.maxRedeem(owner);
  }

  /// @notice Requests to withdraw assets and returns a unique withdraw key
  /// if the requested asset amount is bigger than the idle assets.
  /// If idle assets are available in the Vault, they are withdrawn synchronously
  /// within the `requestWithdraw` call, while any shortfall amount remains
  /// pending for execution by the system.
  ///
  /// @dev Burns shares from owner and sends exactly assets of underlying tokens
  /// to receiver if the idle assets is enough.
  /// If the idle assets is not enough, creates a withdraw request with
  /// the shortfall assets while sending the idle assets to receiver.
  ///
  /// @return withdrawKey The withdraw key that is used in the claim function.
  function requestWithdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public virtual returns (bytes32 withdrawKey) {
    uint256 maxRequestAssets = maxRequestWithdraw(owner);
    if (assets > maxRequestAssets) {
      revert ExceededMaxRequestWithdraw(owner, assets, maxRequestAssets);
    }

    uint256 maxAssets = maxWithdraw(owner);
    uint256 assetsToWithdraw = assets > maxAssets ? maxAssets : assets;
    // always assetsToWithdraw <= assets
    uint256 assetsToRequest = assets - assetsToWithdraw;

    (uint256 shares, uint256 cost) = _previewWithdrawWithCost(assets);
    uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
    uint256 sharesToRequest = shares - sharesToRedeem;

    if (assetsToWithdraw > 0)
      _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

    if (assetsToRequest > 0) {
      withdrawKey = _requestWithdraw(
        _msgSender(),
        receiver,
        owner,
        assetsToRequest,
        sharesToRequest
      );
    }

    return withdrawKey;
  }

  /// @notice Requests to redeem shares and returns a unique withdraw key
  /// if the derived asset amount is bigger than the idle assets.
  /// If idle assets are available in the Vault, they are withdrawn synchronously
  /// within the `requestWithdraw` call, while any shortfall amount remains
  /// pending for execution by the system.
  ///
  /// @dev Burns exactly shares from owner and sends assets of underlying tokens
  /// to receiver if the idle assets is enough,
  /// If the idle assets is not enough, creates a withdraw request with
  /// the shortfall assets while sending the idle assets to receiver.
  ///
  /// @return withdrawKey The withdraw key that is used in the claim function.
  function requestRedeem(
    uint256 shares,
    address receiver,
    address owner
  ) public virtual returns (bytes32 withdrawKey) {
    uint256 maxRequestShares = maxRequestRedeem(owner);
    if (shares > maxRequestShares) {
      revert ExceededMaxRequestRedeem(owner, shares, maxRequestShares);
    }

    (uint256 assets, uint256 cost) = _previewRedeemWithCost(shares);
    uint256 maxAssets = maxWithdraw(owner);

    uint256 assetsToWithdraw = assets > maxAssets ? maxAssets : assets;
    // always assetsToWithdraw <= assets
    uint256 assetsToRequest = assets - assetsToWithdraw;

    uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
    uint256 sharesToRequest = shares - sharesToRedeem;

    if (assetsToWithdraw > 0)
      _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

    if (assetsToRequest > 0) {
      withdrawKey = _requestWithdraw(
        _msgSender(),
        receiver,
        owner,
        assetsToRequest,
        sharesToRequest
      );
    }

    return withdrawKey;
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

  /// @dev requestWithdraw/requestRedeem common workflow.
  function _requestWithdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assetsToRequest,
    uint256 sharesToRequest
  ) internal virtual returns (bytes32) {
    _updateHwmWithdraw(sharesToRequest);

    if (caller != owner) {
      _spendAllowance(owner, caller, sharesToRequest);
    }
    _burn(owner, sharesToRequest);

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 _accRequestedWithdrawAssets;
    bool isPrioritizedAccount = isPrioritized(owner);
    if (isPrioritizedAccount) {
      _accRequestedWithdrawAssets = $.prioritizedAccRequestedWithdrawAssets + assetsToRequest;
      $.prioritizedAccRequestedWithdrawAssets = _accRequestedWithdrawAssets;
    } else {
      _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets + assetsToRequest;
      $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;
    }

    bytes32 withdrawKey = getWithdrawKey(owner, _useNonce(owner));
    $.withdrawRequests[withdrawKey] = GenesisVaultStorage.WithdrawRequest({
      requestedAssets: assetsToRequest,
      accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
      requestTimestamp: block.timestamp,
      owner: owner,
      receiver: receiver,
      isPrioritized: isPrioritizedAccount,
      isClaimed: false
    });
    emit WithdrawRequested(caller, receiver, owner, withdrawKey, assetsToRequest, sharesToRequest);

    emit VaultState(totalAssets(), totalSupply());

    return withdrawKey;
  }

  /// @notice Processes pending withdraw requests with idle assets.
  ///
  /// @dev This is a decentralized function that can be called by anyone.
  ///
  /// @return The assets used to process pending withdraw requests.
  function processPendingWithdrawRequests() public returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 _idleAssets = idleAssets();
    if (_idleAssets == 0) return 0;

    (uint256 remainingAssets, uint256 processedAssetsForPrioritized) = _calcProcessedAssets(
      _idleAssets,
      $.prioritizedProcessedWithdrawAssets,
      $.prioritizedAccRequestedWithdrawAssets
    );
    if (processedAssetsForPrioritized > 0) {
      $.prioritizedProcessedWithdrawAssets += processedAssetsForPrioritized;
    }

    if (remainingAssets == 0) {
      $.assetsToClaim += processedAssetsForPrioritized;
      return processedAssetsForPrioritized;
    }

    (, uint256 processedAssets) = _calcProcessedAssets(
      remainingAssets,
      $.processedWithdrawAssets,
      $.accRequestedWithdrawAssets
    );

    if (processedAssets > 0) $.processedWithdrawAssets += processedAssets;

    uint256 totalProcessedAssets = processedAssetsForPrioritized + processedAssets;

    if (totalProcessedAssets > 0) {
      $.assetsToClaim += totalProcessedAssets;
    }

    return totalProcessedAssets;
  }

  /// @notice Claims a withdraw request if it is executed.
  ///
  /// @param withdrawRequestKey The withdraw key that was returned by requestWithdraw/requestRedeem.
  function claim(bytes32 withdrawRequestKey) public virtual returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.WithdrawRequest memory withdrawRequest = $.withdrawRequests[
      withdrawRequestKey
    ];

    if (withdrawRequest.isClaimed) {
      revert RequestAlreadyClaimed();
    }

    bool isLast = _isLast(
      withdrawRequest.isPrioritized,
      withdrawRequest.accRequestedWithdrawAssets
    );
    bool isExecuted = _isExecuted(
      isLast,
      withdrawRequest.isPrioritized,
      withdrawRequest.accRequestedWithdrawAssets
    );

    if (!isExecuted) {
      revert RequestNotExecuted();
    }

    withdrawRequest.isClaimed = true;

    $.withdrawRequests[withdrawRequestKey] = withdrawRequest;

    uint256 executedAssets;
    // separate workflow for last redeem
    if (isLast) {
      uint256 _processedWithdrawAssets;
      uint256 _accRequestedWithdrawAssets;
      if (withdrawRequest.isPrioritized) {
        _processedWithdrawAssets = $.prioritizedProcessedWithdrawAssets;
        _accRequestedWithdrawAssets = $.prioritizedAccRequestedWithdrawAssets;
      } else {
        _processedWithdrawAssets = $.processedWithdrawAssets;
        _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
      }
      uint256 shortfall = _accRequestedWithdrawAssets - _processedWithdrawAssets;

      if (shortfall > 0) {
        (, executedAssets) = withdrawRequest.requestedAssets.trySub(shortfall);
        withdrawRequest.isPrioritized
          ? $.prioritizedProcessedWithdrawAssets = _accRequestedWithdrawAssets
          : $.processedWithdrawAssets = _accRequestedWithdrawAssets;
      } else {
        uint256 _idleAssets = idleAssets();
        executedAssets = withdrawRequest.requestedAssets + _idleAssets;
        $.assetsToClaim += _idleAssets;
      }
    } else {
      executedAssets = withdrawRequest.requestedAssets;
    }

    $.assetsToClaim -= executedAssets;

    IERC20(asset()).safeTransfer(withdrawRequest.receiver, executedAssets);

    emit Claimed(withdrawRequest.receiver, withdrawRequestKey, executedAssets);
    return executedAssets;
  }

  /// @notice Tells if the withdraw request is claimable or not.
  ///
  /// @param withdrawRequestKey The withdraw key that was returned by requestWithdraw/requestRedeem.
  function isClaimable(bytes32 withdrawRequestKey) external view returns (bool) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.WithdrawRequest memory withdrawRequest = $.withdrawRequests[
      withdrawRequestKey
    ];
    bool isExecuted = _isExecuted(
      _isLast(withdrawRequest.isPrioritized, withdrawRequest.accRequestedWithdrawAssets),
      withdrawRequest.isPrioritized,
      withdrawRequest.accRequestedWithdrawAssets
    );

    return isExecuted && !withdrawRequest.isClaimed;
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
  function idleAssets() public view returns (uint256) {
    return IERC20(asset()).balanceOf(address(this)) - assetsToClaim();
  }

  /// @notice The underlying asset amount requested to withdraw, that is not executed yet.
  function totalPendingWithdraw() public view returns (uint256) {
    return
      prioritizedAccRequestedWithdrawAssets() +
      accRequestedWithdrawAssets() -
      prioritizedProcessedWithdrawAssets() -
      processedWithdrawAssets();
  }

  /// @dev Derives a unique withdraw key based on the user's address and his/her nonce.
  function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
    return keccak256(abi.encodePacked(address(this), user, nonce));
  }

  /*//////////////////////////////////////////////////////////////
                             ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @dev Reserve the execution cost not to affect other's share price.
  function deposit(uint256 assets, address receiver) public override returns (uint256) {
    uint256 maxAssets = maxDeposit(receiver);
    if (assets > maxAssets) {
      revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
    }

    (uint256 shares, uint256 cost) = _previewDepositWithCost(assets);

    _deposit(_msgSender(), receiver, assets, shares);
    return shares;
  }

  /// @dev Reserve the execution cost not to affect other's share price.
  function mint(uint256 shares, address receiver) public override returns (uint256) {
    uint256 maxShares = maxMint(receiver);
    if (shares > maxShares) {
      revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
    }

    (uint256 assets, uint256 cost) = _previewMintWithCost(shares);

    _deposit(_msgSender(), receiver, assets, shares);
    return assets;
  }

  /// @dev This function only works when there are enough idle assets.
  ///      For larger amounts, use requestWithdraw instead.
  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public override returns (uint256) {
    uint256 maxAssets = maxWithdraw(owner);
    if (assets > maxAssets) {
      revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
    }

    (uint256 shares, uint256 cost) = _previewWithdrawWithCost(assets);

    _withdraw(_msgSender(), receiver, owner, assets, shares);
    return shares;
  }

  /// @dev This function only works when there are enough idle assets.
  ///      For larger amounts, use requestRedeem instead.
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public override returns (uint256) {
    uint256 maxShares = maxRedeem(owner);
    if (shares > maxShares) {
      revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
    }

    (uint256 assets, uint256 cost) = _previewRedeemWithCost(shares);

    _withdraw(_msgSender(), receiver, owner, assets, shares);
    return assets;
  }

  /// @inheritdoc ERC4626Upgradeable
  function totalAssets() public view virtual override returns (uint256 assets) {
    (, assets) = (idleAssets() + IGenesisStrategy(strategy()).utilizedAssets()).trySub(
      totalPendingWithdraw()
    );
    return assets;
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
    (uint256 shares, ) = _previewDepositWithCost(assets);
    return shares;
  }

  function _previewDepositWithCost(
    uint256 assets
  ) private view returns (uint256 shares, uint256 cost) {
    // calculate the amount of assets that will be utilized
    uint256 assetsToUtilize = _assetsToUtilize(assets);

    // apply entry fee only to the portion of assets that will be utilized
    if (assetsToUtilize > 0) {
      cost = _costOnTotal(assetsToUtilize, entryCost());
      assets -= cost;
    }

    shares = _convertToShares(assets, Math.Rounding.Floor);
    return (shares, cost);
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewMint(uint256 shares) public view virtual override returns (uint256) {
    (uint256 assets, ) = _previewMintWithCost(shares);
    return assets;
  }

  function _previewMintWithCost(
    uint256 shares
  ) private view returns (uint256 assets, uint256 cost) {
    assets = _convertToAssets(shares, Math.Rounding.Ceil);
    // calculate the amount of assets that will be utilized
    uint256 assetsToUtilize = _assetsToUtilize(assets);

    // apply entry fee only to the portion of assets that will be utilized
    if (assetsToUtilize > 0) {
      cost = _costOnRaw(assetsToUtilize, entryCost());
      assets += cost;
    }
    return (assets, cost);
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
    (uint256 shares, ) = _previewWithdrawWithCost(assets);
    return shares;
  }

  function _previewWithdrawWithCost(
    uint256 assets
  ) private view returns (uint256 shares, uint256 cost) {
    // calc the amount of assets that can not be withdrawn via idle
    uint256 assetsToDeutilize = _assetsToDeutilize(assets);

    // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
    if (assetsToDeutilize > 0) {
      cost = _costOnRaw(assetsToDeutilize, exitCost());
      assets += cost;
    }

    shares = _convertToShares(assets, Math.Rounding.Ceil);
    return (shares, cost);
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
    (uint256 assets, ) = _previewRedeemWithCost(shares);
    return assets;
  }

  function _previewRedeemWithCost(
    uint256 shares
  ) private view returns (uint256 assets, uint256 cost) {
    assets = _convertToAssets(shares, Math.Rounding.Floor);

    // calculate the amount of assets that will be deutilized
    uint256 assetsToDeutilize = _assetsToDeutilize(assets);

    // apply exit fee to the portion of assets that will be deutilized
    if (assetsToDeutilize > 0) {
      cost = _costOnTotal(assetsToDeutilize, exitCost());
      assets -= cost;
    }

    return (assets, cost);
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(address receiver) public view virtual override returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    } else {
      return super.maxDeposit(receiver);
    }
  }

  /// @inheritdoc ERC4626Upgradeable
  function maxMint(address receiver) public view virtual override returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    } else {
      return super.maxMint(receiver);
    }
  }

  /// @dev This is limited by the idle assets.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function maxWithdraw(address owner) public view virtual override returns (uint256) {
    if (paused()) {
      return 0;
    }
    uint256 assets = super.maxWithdraw(owner);
    uint256 withdrawableAssets = idleAssets();
    return assets > withdrawableAssets ? withdrawableAssets : assets;
  }

  /// @dev This is limited by the idle assets.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function maxRedeem(address owner) public view virtual override returns (uint256) {
    if (paused()) {
      return 0;
    }
    uint256 shares = super.maxRedeem(owner);
    // should be rounded floor so that the derived assets can't exceed idle
    uint256 redeemableShares = _convertToShares(idleAssets(), Math.Rounding.Floor);
    return shares > redeemableShares ? redeemableShares : shares;
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
    processPendingWithdrawRequests();

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
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @dev Calculates the processed withdrawal assets.
  ///
  /// @param _idleAssets The idle assets available for processing withdraw requests.
  /// @param _processedWithdrawAssets The value of processedWithdrawAssets storage variable.
  /// @param _accRequestedWithdrawAssets The value of accRequestedWithdrawAssets storage variable.
  ///
  /// @return remainingAssets The remaining asset amount after processing
  /// @return processedAssets The processed asset amount
  function _calcProcessedAssets(
    uint256 _idleAssets,
    uint256 _processedWithdrawAssets,
    uint256 _accRequestedWithdrawAssets
  ) internal pure returns (uint256 remainingAssets, uint256 processedAssets) {
    // check if there is neccessarity to process withdraw requests
    if (_processedWithdrawAssets < _accRequestedWithdrawAssets) {
      uint256 assetsToBeProcessed = _accRequestedWithdrawAssets - _processedWithdrawAssets;
      if (assetsToBeProcessed > _idleAssets) {
        processedAssets = _idleAssets;
      } else {
        processedAssets = assetsToBeProcessed;
        remainingAssets = _idleAssets - processedAssets;
      }
    } else {
      remainingAssets = _idleAssets;
    }
    return (remainingAssets, processedAssets);
  }

  /// @dev Tells if the given withdraw request is last or not.
  function _isLast(
    bool isPrioritizedAccount,
    uint256 accRequestedWithdrawAssetsOfRequest
  ) internal view returns (bool isLast) {
    // return false if withdraw request was not issued (accRequestedWithdrawAssetsOfRequest is zero)
    if (accRequestedWithdrawAssetsOfRequest == 0) {
      return false;
    }
    if (totalSupply() == 0) {
      isLast = isPrioritizedAccount
        ? accRequestedWithdrawAssetsOfRequest == prioritizedAccRequestedWithdrawAssets()
        : accRequestedWithdrawAssetsOfRequest == accRequestedWithdrawAssets();
    }
    return isLast;
  }

  /// @dev Tells if the given withdraw request is executed or not.
  function _isExecuted(
    bool isLast,
    bool isPrioritizedAccount,
    uint256 accRequestedWithdrawAssetsOfRequest
  ) internal view returns (bool isExecuted) {
    // return false if withdraw request was not issued (accRequestedWithdrawAssetsOfRequest is zero)
    if (accRequestedWithdrawAssetsOfRequest == 0) {
      return false;
    }
    if (isLast) {
      // last withdraw is claimable when utilized assets is 0
      isExecuted = IGenesisStrategy(strategy()).utilizedAssets() == 0;
    } else {
      isExecuted = isPrioritizedAccount
        ? accRequestedWithdrawAssetsOfRequest <= prioritizedProcessedWithdrawAssets()
        : accRequestedWithdrawAssetsOfRequest <= processedWithdrawAssets();
    }
    return isExecuted;
  }

  /// @dev Uses nonce of the specified user and increase it
  function _useNonce(address user) internal returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    // For each vault, the nonce has an initial value of 0, can only be incremented by one, and cannot be
    // decremented or reset. This guarantees that the nonce never overflows.
    unchecked {
      // It is important to do x++ and not ++x here.
      return $.nonces[user]++;
    }
  }

  /// @dev Calculates the cost that should be added to an amount `assets` that does not include cost.
  /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
  function _costOnRaw(uint256 assets, uint256 costRate) private pure returns (uint256) {
    return assets.mulDiv(costRate, FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  /// @dev Calculates the cost part of an amount `assets` that already includes cost.
  /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
  function _costOnTotal(uint256 assets, uint256 costRate) private pure returns (uint256) {
    return assets.mulDiv(costRate, costRate + FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  function _assetsToUtilize(uint256 assets) private view returns (uint256) {
    (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());
    return assetsToUtilize;
  }

  function _assetsToDeutilize(uint256 assets) private view returns (uint256) {
    (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());
    return assetsToDeutilize;
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

  /// @notice The underlying asset amount that is in Vault and
  /// reserved to claim for the executed withdraw requests.
  function assetsToClaim() public view returns (uint256) {
    return GenesisVaultStorage.layout().assetsToClaim;
  }

  /// @dev The accumulated underlying asset amount requested to withdraw by the normal users.
  function accRequestedWithdrawAssets() public view returns (uint256) {
    return GenesisVaultStorage.layout().accRequestedWithdrawAssets;
  }

  /// @dev The accumulated underlying asset amount processed for the normal withdraw requests.
  function processedWithdrawAssets() public view returns (uint256) {
    return GenesisVaultStorage.layout().processedWithdrawAssets;
  }

  /// @dev The accumulated underlying asset amount requested to withdraw by the prioritized users.
  function prioritizedAccRequestedWithdrawAssets() public view returns (uint256) {
    return GenesisVaultStorage.layout().prioritizedAccRequestedWithdrawAssets;
  }

  /// @dev The accumulated underlying asset amount processed for the prioritized withdraw requests.
  function prioritizedProcessedWithdrawAssets() public view returns (uint256) {
    return GenesisVaultStorage.layout().prioritizedProcessedWithdrawAssets;
  }

  /// @dev Returns the state of a withdraw request for the withdrawKey.
  function withdrawRequests(
    bytes32 withdrawKey
  ) public view returns (GenesisVaultStorage.WithdrawRequest memory) {
    return GenesisVaultStorage.layout().withdrawRequests[withdrawKey];
  }

  /// @dev Returns a nonce of a user that are reserved to generate the next withdraw key.
  function nonces(address user) public view returns (uint256) {
    return GenesisVaultStorage.layout().nonces[user];
  }

  /// @notice The address of admin who is responsible for pausing/unpausing vault.
  function admin() public view returns (address) {
    return GenesisVaultStorage.layout().admin;
  }

  /// @notice When this vault is shutdown, only withdrawals are available. It can't be reverted.
  function isShutdown() public view returns (bool) {
    return GenesisVaultStorage.layout().shutdown;
  }
}
