import { BigNumber } from "@ethersproject/bignumber";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import { ethers, network } from "hardhat";
import { range } from "ramda";

import { Bank, CAKE, PEUPLE, Staking, SwapPool } from "../typechain";

chai.use(chaiAsPromised);
const { expect } = chai;

const _10_18 = BigNumber.from("1000000000000000000");
const ether = (x: number) => _10_18.mul(x);
const hundredBillion = _10_18.mul(100_000_000_000);
const oneBillion = _10_18.mul(1_000_000_000);
const oneBillionPlusTax = oneBillion.mul(125).div(100);
const halfBillion = _10_18.mul(500_000_000);
const oneMillion = _10_18.mul(1_000_000);
const oneThousand = _10_18.mul(1_000);
const tenThousand = oneThousand.mul(10);

const MAX_STAKE = ether(2 ** 32 - 1);

const expense = async (wallet: SignerWithAddress) => {
  const initialBalance = await wallet.getBalance();
  return {
    isEqualTo: async (maxSpent: number) => {
      const newBalance = await wallet.getBalance();
      expect(initialBalance.sub(newBalance).toNumber()).to.equal(maxSpent);
    },
  };
};

const days = async (n: number) => {
  await network.provider.send("evm_increaseTime", [n * 24 * 60 * 60]);
  await network.provider.send("evm_mine");
};

describe("PEUPLE", () => {
  let swapPool: SwapPool;
  let cake: CAKE;
  let cakeOwner: SignerWithAddress;
  let peupleOwner: SignerWithAddress;
  let peuple: PEUPLE;
  let bankOwner: SignerWithAddress;
  let bank: Bank;
  let stakingOwner: SignerWithAddress;
  let staking: Staking;
  let holder_1: SignerWithAddress;
  let holder_2: SignerWithAddress;
  let holder_3: SignerWithAddress;
  let holder_4: SignerWithAddress;
  let buyPeuple: (
    holder: SignerWithAddress,
    amount: BigNumber
  ) => Promise<void>;
  let sellPeuple: (
    holder: SignerWithAddress,
    amount: BigNumber
  ) => Promise<void>;
  let stakePeuple: (
    holder: SignerWithAddress,
    amount: BigNumber,
    months?: 1 | 2 | 3
  ) => Promise<void>;
  let buyAndStakeWithTax: (
    holder: SignerWithAddress,
    amount: BigNumber,
    months?: 1 | 2 | 3
  ) => Promise<void>;
  let buyAndStake: (
    holder: SignerWithAddress,
    amount: BigNumber,
    months?: 1 | 2 | 3
  ) => Promise<void>;
  let createNewBlock: () => Promise<void>;
  let sendCakeRewards: (amount: BigNumber) => Promise<void>;
  beforeEach(async () => {
    const [swapPoolOwner, co, po, bo, so, h1, h2, h3, h4] =
      await ethers.getSigners();
    cakeOwner = co;
    peupleOwner = po;
    bankOwner = bo;
    stakingOwner = so;
    holder_1 = h1;
    holder_2 = h2;
    holder_3 = h3;
    holder_4 = h4;
    buyPeuple = async (holder, amount) => {
      const cakeAmount = amount.div(10 ** 6);
      await cake.connect(cakeOwner).transfer(holder.address, cakeAmount);
      await cake.connect(holder).approve(swapPool.address, cakeAmount);
      await swapPool.connect(holder).buyPeupleWithCake(cakeAmount);
    };
    sellPeuple = async (holder, amount) => {
      await peuple.connect(holder).approve(swapPool.address, amount);
      await swapPool.connect(holder).sellPeupleForCake(amount);
    };
    stakePeuple = async (holder, amount, months = 1) => {
      await peuple.connect(holder).approve(staking.address, amount);
      await staking.connect(holder).stake(amount, months);
    };
    buyAndStakeWithTax = async (holder, amount, months) => {
      await buyPeuple(holder, amount);
      const swappedPeuple = amount.mul(80).div(100);
      await stakePeuple(holder, swappedPeuple, months);
    };
    buyAndStake = async (holder, amount, months) => {
      await buyPeuple(holder, amount);
      await stakePeuple(holder, amount, months);
    };
    createNewBlock = async () => {
      const canCreate = await staking.canCreateNewBlock();
      if (!canCreate) throw Error("Can NOT create new block");
      await staking.createNewBlock();
    };
    sendCakeRewards = async (amount) => {
      await cake.connect(cakeOwner).approve(staking.address, amount);
      await staking.connect(cakeOwner).sendCakeRewards(amount);
    };

    const cakeFactory = await ethers.getContractFactory("CAKE");
    cake = await cakeFactory.connect(cakeOwner).deploy();

    const swapPoolFactory = await ethers.getContractFactory("SwapPool");
    swapPool = await swapPoolFactory
      .connect(swapPoolOwner)
      .deploy(cake.address);

    const bankFactory = await ethers.getContractFactory("Bank");
    bank = await bankFactory.connect(bankOwner).deploy();

    const im = await ethers.getContractFactory("IterableMapping");
    const IterableMapping = (await im.deploy()).address;
    const peupleFactory = await ethers.getContractFactory("PEUPLE", {
      libraries: {
        IterableMapping,
      },
    });
    peuple = await peupleFactory
      .connect(peupleOwner)
      .deploy(cake.address, swapPool.address, bankOwner.address);
    await peuple
      .connect(peupleOwner)
      .transfer(swapPool.address, oneBillion.mul(90));

    const stakingFactory = await ethers.getContractFactory("Staking");
    staking = await stakingFactory
      .connect(stakingOwner)
      .deploy(peuple.address, cake.address, swapPool.address);
    await peuple.connect(peupleOwner).excludeFromFees(staking.address, true);
  });
  it("initializes token contract and swap pool", async () => {
    const peupleOwnerBalance = await peuple.balanceOf(peupleOwner.address);
    expect(peupleOwnerBalance).to.equal(oneBillion.mul(10));
    expect(await peuple.balanceOf(holder_1.address)).to.equal("0");
    expect(await peuple.totalSupply()).to.equal(hundredBillion);

    const cakeSupply = await cake.totalSupply();
    expect(cakeSupply).to.equal(oneMillion.mul(100));
  });
  it("stakes max stake", async () => {
    await cake.transfer(holder_1.address, tenThousand);
    expect(await cake.balanceOf(holder_1.address)).to.equal(tenThousand);
    await cake.connect(holder_1).approve(swapPool.address, tenThousand);
    await swapPool.connect(holder_1).buyPeupleWithCake(ether(5000 * 1.25));
    expect(await peuple.balanceOf(holder_1.address)).to.equal(
      oneBillion.mul(5)
    );
    await stakePeuple(holder_1, MAX_STAKE);
  });
  it("does not create block when no stakers", async () => {
    await days(2);
    await sendCakeRewards(oneThousand);
    expect(await staking.currentBlockNumber()).to.equal(0);
  });
  it("can not create block when no stakers", async () => {
    await days(2);
    await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
    expect(await staking.canCreateNewBlock()).to.be.false;
  });
  describe("when first holder buys one billion PEUPLE", () => {
    beforeEach(async () => {
      await buyPeuple(holder_1, oneBillionPlusTax);
    });
    it("rejects null amount", async () => {
      await expect(stakePeuple(holder_1, BigNumber.from(0))).to.be.rejectedWith(
        Error
      );
    });
    it("rejects too big amount", async () => {
      await expect(stakePeuple(holder_1, MAX_STAKE.add(1))).to.be.rejectedWith(
        Error
      );
    });
    it("rejects 0 months staking", async () => {
      await expect(
        stakePeuple(holder_1, oneBillion, 0 as 1)
      ).to.be.rejectedWith(Error);
    });
    it("rejects 4 months staking", async () => {
      await expect(
        stakePeuple(holder_1, oneBillion, 4 as 1)
      ).to.be.rejectedWith(Error);
    });
    it("stakes one peuple", async () => {
      await stakePeuple(holder_1, ether(1));
      expect(await staking.connect(holder_1).computeHolderStake()).to.equal(
        ether(1)
      );
      expect(await staking.totalStaked()).to.equal(ether(1));
    });
    it("stakes half a billion for one month, twice", async () => {
      // const spent = await expense(holder_1);
      await stakePeuple(holder_1, halfBillion);
      // await spent.isEqualTo(73697743125270);
      await stakePeuple(holder_1, halfBillion);
      // await spent.isEqualTo(130256001042048);
      expect(await staking.connect(holder_1).computeHolderStake()).to.equal(
        oneBillion
      );
      expect(await staking.totalStaked()).to.equal(oneBillion);
    });

    describe("when first holder stakes all his peuple", () => {
      beforeEach(async () => {
        await stakePeuple(holder_1, oneBillion);
      });
      it("can't create new block", async () => {
        expect(await staking.canCreateNewBlock()).to.be.false;
      });
      describe("when second holder buys and sells 1 billion peuple", async () => {
        beforeEach(async () => {
          await buyPeuple(holder_2, oneBillionPlusTax);
          await sellPeuple(holder_2, oneBillion);
          await days(1);
          await buyPeuple(holder_2, ether(1));
        });
        it("can create new block", async () => {
          expect(await staking.canCreateNewBlock()).to.be.true;
        });
        describe("when third holder buys and stakes 1 billion peuple two days later", async () => {
          beforeEach(async () => {
            await days(2);
            await buyAndStakeWithTax(holder_3, oneBillionPlusTax);
          });
          it("stores dividends for first holder", async () => {
            expect(
              await staking.connect(holder_1).computeHolderDividends()
            ).to.be.gt(ether(1));
          });
        });
      });
    });
  });

  describe("when three holders buy 1 billion peuple, first two stake it all", () => {
    beforeEach(async () => {
      await buyAndStakeWithTax(holder_1, oneBillionPlusTax);
      await buyAndStakeWithTax(holder_2, oneBillionPlusTax);
      await buyPeuple(holder_3, oneBillionPlusTax);
      expect(await cake.balanceOf(holder_3.address)).to.equal(0);
    });
    describe("when fourth holder buys and sells one billion peuple", async () => {
      beforeEach(async () => {
        await buyPeuple(holder_4, oneBillionPlusTax);
        await sellPeuple(holder_4, oneBillion);
        await days(1);
        await buyPeuple(holder_4, ether(1)); // To force dividend distribution
      });
      describe("when first block is created", () => {
        beforeEach(async () => {
          await days(2);
          await createNewBlock();
        });
        it("distributes dividends to all three holders", async () => {
          const dividends_1 = await staking
            .connect(holder_1)
            .computeHolderDividends();
          const dividends_2 = await staking
            .connect(holder_2)
            .computeHolderDividends();
          const dividends_3 = await cake.balanceOf(holder_3.address);
          expect(dividends_1).to.equal(dividends_2);
          expect(dividends_2.gt(dividends_3.mul(1_000_000))).to.be.true;
        });
        describe("when fourth holder buys and sells one billion peuple AGAIN", async () => {
          beforeEach(async () => {
            await buyPeuple(holder_4, oneBillionPlusTax);
            await sellPeuple(holder_4, oneBillion);
            await days(1);
            await buyPeuple(holder_4, ether(1)); // To force dividend distribution
          });
          describe("when second block is created", () => {
            beforeEach(async () => {
              await days(2);
              await createNewBlock();
            });
            it("distributes dividends to all three holders", async () => {
              const dividends_1 = await staking
                .connect(holder_1)
                .computeHolderDividends();
              const dividends_2 = await staking
                .connect(holder_2)
                .computeHolderDividends();
              const dividends_3 = await cake.balanceOf(holder_3.address);
              expect(dividends_1).to.be.gt(0);
              expect(dividends_1).to.equal(dividends_2);
              expect(dividends_2.gt(dividends_3.mul(1_000_000))).to.be.true;
            });
          });
        });
      });
    });
  });

  describe("when two holders buy 1 billion peuple, first one stakes it all", () => {
    beforeEach(async () => {
      await buyAndStakeWithTax(holder_1, oneBillionPlusTax);
      await buyPeuple(holder_2, oneBillionPlusTax);
    });
    describe("when first block is created", () => {
      beforeEach(async () => {
        await buyPeuple(holder_3, oneBillionPlusTax);
        await sellPeuple(holder_3, oneBillion);
        await days(1);
        await buyPeuple(holder_4, ether(1)); // To force swap
        await days(2);
        await createNewBlock();
      });
      describe("when second holder stakes it all", () => {
        beforeEach(async () => {
          await stakePeuple(holder_2, oneBillion);
        });
        it("does not give any dividends to second holder yet", async () => {
          const dividends_2 = await staking
            .connect(holder_2)
            .computeHolderDividends();
          expect(dividends_2).to.equal(0);
        });
      });
    });
  });

  describe("when fee rates are all set to zero", () => {
    beforeEach(async () => {
      const p = peuple.connect(peupleOwner);
      await p.setCAKERewardsFee(0);
      await p.setLiquidityFee(0);
      await p.setMarketingFee(0);
    });
    describe("when first holder buys and stakes one billion peuple for one month", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
      });
      describe("for one thousand cake dividends", () => {
        beforeEach(async () => {
          await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
          await days(2);
          await createNewBlock();
        });
        it("redistributes all dividends to holder", async () => {
          const dividends = await staking
            .connect(holder_1)
            .computeHolderDividends();
          expect(dividends).to.equal(oneBillion);
        });
        it("holder can withdraw dividends", async () => {
          const dividends = await staking
            .connect(holder_1)
            .withdrawAllRewardsAndDividends();
          expect(dividends).to.equal(oneBillion);
          const balance = await peuple.balanceOf(holder_1.address);
          expect(balance).to.equal(oneBillion);
        });
      });
      it("redistributes all peuple rewards to holder", async () => {
        await peuple.connect(peupleOwner).approve(staking.address, oneBillion);
        await peuple.connect(peupleOwner).transfer(staking.address, oneBillion);
        await days(2);
        await createNewBlock();
        const rewards = await staking.connect(holder_1).computeHolderRewards();
        expect(rewards).to.equal(oneBillion);
      });
      describe("when 1 thousand cake reward is sent two days later", () => {
        beforeEach(async () => {
          await days(2);
          await sendCakeRewards(oneThousand);
        });
        it("redistributes all cake rewards to holder", async () => {
          expect(
            await staking.connect(holder_1).computeHolderRewards()
          ).to.equal(oneBillion);
        });
        describe("when 1 thousand cake reward is sent two days later AGAIN", () => {
          beforeEach(async () => {
            await days(2);
            await sendCakeRewards(oneThousand);
          });
          it("redistributes all cake rewards to holder", async () => {
            expect(
              await staking.connect(holder_1).computeHolderRewards()
            ).to.equal(oneBillion.mul(2));
          });
        });
      });
      describe("when second holder buys one billion peuple, but does not stake", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion);
        });
        it("distributes dividends evenly", async () => {
          await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
          await days(2);
          await createNewBlock();
          const dividends_1 = await staking
            .connect(holder_1)
            .computeHolderDividends();
          const dividends_2 = await staking
            .connect(holder_2)
            .computeHolderDividends();
          expect(dividends_1).to.equal(dividends_2);
        });
      });
      describe("when second holder buys and stakes for 2 months", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion, 2);
        });
        it("redistributes more cake rewards to second holder", async () => {
          await days(2);
          await sendCakeRewards(oneThousand);

          const rewards_1 = await staking
            .connect(holder_1)
            .computeHolderRewards();
          const rewards_2 = await staking
            .connect(holder_2)
            .computeHolderRewards();
          expect(rewards_2.gt(rewards_1)).to.be.true;
          const bonus = await staking.percentBonusForTwoMonthStaking();
          expect(rewards_2).to.equal(
            rewards_1.add(rewards_1.mul(bonus).div(100))
          );
        });
        it("can set bonus rate", async () => {
          await staking
            .connect(stakingOwner)
            .setPercentBonusForTwoMonthStaking(100);
          expect(await staking.percentBonusForTwoMonthStaking()).to.equal(100);
        });
        it("can't set bonus rate higher than 100%", async () => {
          await expect(
            staking.connect(stakingOwner).setPercentBonusForTwoMonthStaking(101)
          ).to.be.rejectedWith(Error);
        });
      });
      describe("when second holder buys and stakes for 3 months", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion, 3);
        });
        it("redistributes more cake rewards to second holder", async () => {
          await days(2);
          await sendCakeRewards(oneThousand);

          const rewards_1 = await staking
            .connect(holder_1)
            .computeHolderRewards();
          const rewards_2 = await staking
            .connect(holder_2)
            .computeHolderRewards();
          expect(rewards_2.gt(rewards_1)).to.be.true;
          const bonus = await staking.percentBonusForThreeMonthStaking();
          expect(rewards_2).to.equal(
            rewards_1.add(rewards_1.mul(bonus).div(100))
          );
          expect(rewards_2).to.equal(oneThousand.mul(1_000_000).mul(2).div(3));
          expect(rewards_1).to.equal(oneThousand.mul(1_000_000).mul(1).div(3));
        });
        it("can set bonus rate", async () => {
          await staking
            .connect(stakingOwner)
            .setPercentBonusForThreeMonthStaking(200);
          expect(await staking.percentBonusForThreeMonthStaking()).to.equal(
            200
          );
        });
        it("can't set bonus rate higher than 200%", async () => {
          await expect(
            staking
              .connect(stakingOwner)
              .setPercentBonusForThreeMonthStaking(201)
          ).to.be.rejectedWith(Error);
        });
      });
    });
    describe("when two holders buy and stake one billion peuple each", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
        await buyAndStake(holder_2, oneBillion);
      });
      it("redistributes dividends evenly", async () => {
        await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
        await days(2);
        await createNewBlock();
        const dividends_1 = await staking
          .connect(holder_1)
          .computeHolderDividends();
        const dividends_2 = await staking
          .connect(holder_1)
          .computeHolderDividends();
        expect(dividends_1).to.equal(dividends_2).to.equal(oneBillion.div(2));
      });
      it("redistributes cake rewards evenly", async () => {
        await days(2);
        await sendCakeRewards(oneThousand);
        const rewards_1 = await staking
          .connect(holder_1)
          .computeHolderRewards();
        const rewards_2 = await staking
          .connect(holder_1)
          .computeHolderRewards();
        expect(rewards_1).to.equal(rewards_2).to.equal(oneBillion.div(2));
      });
      describe("when first holder has higher social bonus", () => {
        beforeEach(async () => {
          await staking
            .connect(stakingOwner)
            .setHolderSocialPercentBonus(holder_1.address, 100);
        });
        it("redistributes more rewards to first holder", async () => {
          await days(2);
          await sendCakeRewards(oneThousand);
          const rewards_1 = await staking
            .connect(holder_1)
            .computeHolderRewards();
          const rewards_2 = await staking
            .connect(holder_2)
            .computeHolderRewards();
          expect(rewards_1).to.equal(rewards_2.mul(2));
          expect(rewards_1).to.equal(oneThousand.mul(1_000_000).mul(2).div(3));
          expect(rewards_2).to.equal(oneThousand.mul(1_000_000).mul(1).div(3));
        });
        describe("when block is created but then first holder gets his social bonus back to zero", () => {
          beforeEach(async () => {
            await days(2);
            await sendCakeRewards(oneThousand);
            await staking
              .connect(stakingOwner)
              .setHolderSocialPercentBonus(holder_1.address, 0);
          });
          it("still redistributes more rewards to first holder", async () => {
            const rewards_1 = await staking
              .connect(holder_1)
              .computeHolderRewards();
            const rewards_2 = await staking
              .connect(holder_2)
              .computeHolderRewards();
            expect(rewards_1).to.equal(rewards_2.mul(2));
            expect(rewards_1).to.equal(
              oneThousand.mul(1_000_000).mul(2).div(3)
            );
            expect(rewards_2).to.equal(
              oneThousand.mul(1_000_000).mul(1).div(3)
            );
          });
        });
      });
    });

    describe("when single holder buys one billion and stakes it in 20 parts", () => {
      beforeEach(async () => {
        await buyPeuple(holder_1, oneBillion);
        for await (let i of range(0, 20)) {
          await stakePeuple(holder_1, oneBillion.div(20));
        }
      });
      describe("when 20 blocks with dividends are created", () => {
        beforeEach(async () => {
          for await (let i of range(0, 20)) {
            await cake.connect(cakeOwner).transfer(staking.address, ether(10));
            await days(2);
            await createNewBlock();
          }
        });
        it("runs out of gas when computing dividends", async () => {
          expect(
            staking.connect(holder_1).computeHolderDividends()
          ).to.be.rejectedWith(Error);
        });
        describe("when dividends are precomputed once", () => {
          beforeEach(async () => {
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
          });
          it("computes dividends", async () => {
            const dividends = await staking
              .connect(holder_1)
              .computeHolderDividends();
            expect(dividends).to.equal(
              BigNumber.from("200000000000000000000000000")
            );
          });
        });
        describe("when dividends are precomputed for first ten selected stakes", () => {
          beforeEach(async () => {
            for await (let i of range(0, 10)) {
              await staking
                .connect(holder_1)
                .precomputeRewardsAndDividendsForStake(i);
            }
          });
          it("computes dividends", async () => {
            const dividends = await staking
              .connect(holder_1)
              .computeHolderDividends();
            expect(dividends).to.equal(
              BigNumber.from("200000000000000000000000000")
            );
          });
        });
      });
      describe("when 20 blocks with rewards are created", () => {
        beforeEach(async () => {
          for await (let i of range(0, 20)) {
            await peuple
              .connect(peupleOwner)
              .transfer(staking.address, oneMillion.mul(10));
            await days(2);
            await createNewBlock();
          }
        });
        it("runs out of gas when computing dividends", async () => {
          expect(
            staking.connect(holder_1).computeHolderRewards()
          ).to.be.rejectedWith(Error);
        });
        describe("when rewards are precomputed thrice", () => {
          beforeEach(async () => {
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
          });
          it("computes rewards", async () => {
            const rewards = await staking
              .connect(holder_1)
              .computeHolderRewards();
            expect(rewards).to.equal(oneMillion.mul(10).mul(20));
          });
          describe("when another block is created", () => {
            beforeEach(async () => {
              await peuple
                .connect(peupleOwner)
                .transfer(staking.address, oneMillion.mul(10));
              await days(2);
              await createNewBlock();
            });
            it("computes rewards after single precomputation", async () => {
              await staking
                .connect(holder_1)
                .precomputeAllRewardsAndDividends();
              const rewards = await staking
                .connect(holder_1)
                .computeHolderRewards();
              expect(rewards).to.equal(oneMillion.mul(10).mul(21));
            });
          });
        });
      });
      describe("when second holder buys and stakes one billion, but first holder has better social score", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion);
          await staking
            .connect(stakingOwner)
            .setHolderSocialPercentBonus(holder_1.address, 100);
        });
        describe("when 10 blocks with rewards are created", () => {
          beforeEach(async () => {
            for await (let i of range(0, 10)) {
              await peuple
                .connect(peupleOwner)
                .transfer(staking.address, oneMillion.mul(10));
              await days(2);
              await createNewBlock();
            }
          });
          it("precomputes rewards with social bonus", async () => {
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            const rewards_1 = await staking
              .connect(holder_1)
              .computeHolderRewards();
            const rewards_2 = await staking
              .connect(holder_2)
              .computeHolderRewards();
            expect(rewards_1).to.equal(
              BigNumber.from("66666666666666666666666400")
            );
            expect(rewards_2).to.equal(
              BigNumber.from("33333333333333333333333330")
            );
          });
          describe("when first holder gets his social score back to zero before another 10 blocks are created", () => {
            beforeEach(async () => {
              await staking
                .connect(stakingOwner)
                .setHolderSocialPercentBonus(holder_1.address, 0);
              for await (let i of range(0, 10)) {
                await peuple
                  .connect(peupleOwner)
                  .transfer(staking.address, oneMillion.mul(10));
                await days(2);
                await createNewBlock();
              }
            });
            it("precomputes rewards with social bonus", async () => {
              for await (let i of range(0, 3)) {
                await staking
                  .connect(holder_1)
                  .precomputeAllRewardsAndDividends();
              }
              const rewards_1 = await staking
                .connect(holder_1)
                .computeHolderRewards();
              const rewards_2 = await staking
                .connect(holder_2)
                .computeHolderRewards();
              expect(rewards_1).to.equal(
                BigNumber.from("66666666666666666666666400").add(
                  oneMillion.mul(50)
                )
              );
              expect(rewards_2).to.equal(
                BigNumber.from("33333333333333333333333330").add(
                  oneMillion.mul(50)
                )
              );
            });
          });
        });
      });
    });
    describe("when single holder buys one billion and stakes it for 3 months in 20 parts", () => {
      beforeEach(async () => {
        await buyPeuple(holder_1, oneBillion);
        for await (let i of range(0, 20)) {
          await stakePeuple(holder_1, oneBillion.div(20), 3);
        }
      });
      describe("when second holder buys and stakes one billion for one month only", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion);
        });
        describe("when 20 blocks with rewards are created", () => {
          beforeEach(async () => {
            for await (let i of range(0, 20)) {
              await peuple
                .connect(peupleOwner)
                .transfer(staking.address, oneMillion.mul(10));
              await days(2);
              await createNewBlock();
            }
          });
          it("precomputes rewards with time bonus", async () => {
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            await staking.connect(holder_1).precomputeAllRewardsAndDividends();
            const rewards = await staking
              .connect(holder_1)
              .computeHolderRewards();
            expect(rewards).to.equal(
              BigNumber.from("133333333333333333333333200")
            );
            const rewards_2 = await staking
              .connect(holder_2)
              .computeHolderRewards();
            expect(rewards_2).to.equal(
              BigNumber.from("66666666666666666666666660")
            );
          });
        });
      });
    });
  });
});
