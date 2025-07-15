import { expect } from "chai";
import { ethers } from "hardhat";
import { deployDiamond } from "../scripts/deploy-diamond";

describe("Diamond BaseVolStrike Compatibility", function () {
  let diamondAddress: string;
  let owner: any;
  let admin: any;
  let operator: any;
  let clearingHouse: any;
  let mockUSDC: any;
  let mockOracle: any;

  beforeEach(async function () {
    [owner, admin, operator] = await ethers.getSigners();

    // Deploy mock contracts
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockUSDC = await MockERC20.deploy("USDC", "USDC", 6);
    await mockUSDC.waitForDeployment();

    const MockOracle = await ethers.getContractFactory("MockAggregatorV3");
    mockOracle = await MockOracle.deploy(8, "BTC/USD", 1);
    await mockOracle.waitForDeployment();

    // Deploy mock clearing house
    const MockClearingHouse = await ethers.getContractFactory("MockClearingHouse");
    clearingHouse = await MockClearingHouse.deploy();
    await clearingHouse.waitForDeployment();

    // Deploy diamond
    diamondAddress = await deployDiamond(
      await mockUSDC.getAddress(),
      await mockOracle.getAddress(),
      admin.address,
      operator.address,
      200, // 2% commission
      await clearingHouse.getAddress(),
    );
  });

  describe("Initialization", function () {
    it("should have correct initial values", async function () {
      const viewFacet = await ethers.getContractAt("ViewFacet", diamondAddress);

      expect(await viewFacet.commissionfee()).to.equal(200);

      const [adminAddr, operatorAddr, clearingHouseAddr, tokenAddr] = await viewFacet.addresses();
      expect(adminAddr).to.equal(admin.address);
      expect(operatorAddr).to.equal(operator.address);
      expect(clearingHouseAddr).to.equal(await clearingHouse.getAddress());
      expect(tokenAddr).to.equal(await mockUSDC.getAddress());
    });
  });

  describe("Round Management", function () {
    it("should have currentEpoch function", async function () {
      const roundFacet = await ethers.getContractAt("RoundManagementFacet", diamondAddress);

      const currentEpoch = await roundFacet.currentEpoch();
      expect(currentEpoch).to.be.a("bigint");
    });
  });

  describe("Admin Functions", function () {
    it("should allow admin to set commission fee", async function () {
      const adminFacet = await ethers.getContractAt("AdminFacet", diamondAddress);
      const viewFacet = await ethers.getContractAt("ViewFacet", diamondAddress);

      await adminFacet.connect(admin).setCommissionfee(300);
      expect(await viewFacet.commissionfee()).to.equal(300);
    });

    it("should allow admin to set operator", async function () {
      const adminFacet = await ethers.getContractAt("AdminFacet", diamondAddress);
      const viewFacet = await ethers.getContractAt("ViewFacet", diamondAddress);

      const newOperator = (await ethers.getSigners())[3];
      await adminFacet.connect(admin).setOperator(newOperator.address);

      const [, operatorAddr] = await viewFacet.addresses();
      expect(operatorAddr).to.equal(newOperator.address);
    });
  });

  describe("View Functions", function () {
    it("should have all required view functions", async function () {
      const viewFacet = await ethers.getContractAt("ViewFacet", diamondAddress);

      // Test balances function
      const [depositBalance, couponBalance, totalBalance] = await viewFacet.balances(owner.address);
      expect(depositBalance).to.be.a("bigint");
      expect(couponBalance).to.be.a("bigint");
      expect(totalBalance).to.be.a("bigint");

      // Test rounds function
      const round = await viewFacet.rounds(0, 0);
      expect(round.epoch).to.equal(0);
      expect(round.isStarted).to.be.a("boolean");
      expect(round.isSettled).to.be.a("boolean");

      // Test filledOrders function
      const orders = await viewFacet.filledOrders(0);
      expect(orders).to.be.an("array");

      // Test userFilledOrders function
      const userOrders = await viewFacet.userFilledOrders(0, owner.address);
      expect(userOrders).to.be.an("array");

      // Test lastFilledOrderId function
      const lastOrderId = await viewFacet.lastFilledOrderId();
      expect(lastOrderId).to.be.a("bigint");

      // Test lastSettledFilledOrderId function
      const lastSettledOrderId = await viewFacet.lastSettledFilledOrderId();
      expect(lastSettledOrderId).to.be.a("bigint");

      // Test priceInfos function
      const priceInfos = await viewFacet.priceInfos();
      expect(priceInfos).to.be.an("array");
      expect(priceInfos.length).to.equal(2); // BTC/USD and ETH/USD
    });
  });

  describe("Order Processing", function () {
    it("should have order processing functions", async function () {
      const orderFacet = await ethers.getContractAt("OrderProcessingFacet", diamondAddress);

      // Test countUnsettledFilledOrders function
      const unsettledCount = await orderFacet.countUnsettledFilledOrders(0);
      expect(unsettledCount).to.be.a("bigint");
    });
  });

  describe("Redemption", function () {
    it("should have redemption functions", async function () {
      const redemptionFacet = await ethers.getContractAt("RedemptionFacet", diamondAddress);

      // Test redeemVault function
      const redeemVault = await redemptionFacet.redeemVault();
      expect(redeemVault).to.be.a("string");

      // Test redeemFee function
      const redeemFee = await redemptionFacet.redeemFee();
      expect(redeemFee).to.be.a("bigint");
    });
  });

  describe("Diamond Standard Functions", function () {
    it("should have diamond loupe functions", async function () {
      const loupeFacet = await ethers.getContractAt("DiamondLoupeFacet", diamondAddress);

      // Test facets function
      const facets = await loupeFacet.facets();
      expect(facets).to.be.an("array");
      expect(facets.length).to.be.greaterThan(0);

      // Test facetAddresses function
      const facetAddresses = await loupeFacet.facetAddresses();
      expect(facetAddresses).to.be.an("array");
      expect(facetAddresses.length).to.be.greaterThan(0);
    });
  });

  describe("Function Compatibility", function () {
    it("should maintain the same function signatures as BaseVolStrike", async function () {
      // Test that all major functions exist and can be called
      const viewFacet = await ethers.getContractAt("ViewFacet", diamondAddress);
      const adminFacet = await ethers.getContractAt("AdminFacet", diamondAddress);
      const roundFacet = await ethers.getContractAt("RoundManagementFacet", diamondAddress);

      // These should not throw errors
      await expect(viewFacet.commissionfee()).to.not.be.reverted;
      await expect(viewFacet.addresses()).to.not.be.reverted;
      await expect(viewFacet.balances(owner.address)).to.not.be.reverted;
      await expect(viewFacet.rounds(0, 0)).to.not.be.reverted;
      await expect(viewFacet.filledOrders(0)).to.not.be.reverted;
      await expect(viewFacet.userFilledOrders(0, owner.address)).to.not.be.reverted;
      await expect(viewFacet.lastFilledOrderId()).to.not.be.reverted;
      await expect(viewFacet.lastSettledFilledOrderId()).to.not.be.reverted;
      await expect(viewFacet.priceInfos()).to.not.be.reverted;
      await expect(roundFacet.currentEpoch()).to.not.be.reverted;
    });
  });

  describe("Error Handling", function () {
    it("should revert with proper error messages", async function () {
      const adminFacet = await ethers.getContractAt("AdminFacet", diamondAddress);

      // Test that only admin can call admin functions
      await expect(adminFacet.connect(operator).setCommissionfee(300)).to.be.revertedWith(
        "Only admin",
      );

      // Test that commission fee has limits
      await expect(
        adminFacet.connect(admin).setCommissionfee(600), // > 5%
      ).to.be.revertedWithCustomError(adminFacet, "InvalidCommissionFee");
    });
  });
});
