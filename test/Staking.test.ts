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
  let sendPeupleRewards: (
    amount: BigNumber,
    blockDays?: number
  ) => Promise<void>;
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
    sendPeupleRewards = async (amount, blockDays) => {
      await peuple.connect(peupleOwner).transfer(staking.address, amount);
      if (blockDays) {
        await days(blockDays);
        await createNewBlock();
      }
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
      expect(
        await staking.connect(holder_1).computeHolderTotalStakeAmount()
      ).to.equal(ether(1));
      expect(await staking.currentTotalStake()).to.equal(ether(1));
    });
    it("stakes half a billion for one month, twice", async () => {
      // const spent = await expense(holder_1);
      await stakePeuple(holder_1, halfBillion);
      // await spent.isEqualTo(73697743125270);
      await stakePeuple(holder_1, halfBillion);
      // await spent.isEqualTo(130256001042048);
      expect(
        await staking.connect(holder_1).computeHolderTotalStakeAmount()
      ).to.equal(oneBillion);
      expect(await staking.currentTotalStake()).to.equal(oneBillion);
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
              await staking.connect(holder_1).computeDividends(0)
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
            .computeDividends(0);
          const dividends_2 = await staking
            .connect(holder_2)
            .computeDividends(0);
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
                .computeDividends(0);
              const dividends_2 = await staking
                .connect(holder_2)
                .computeDividends(0);
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
            .computeDividends(0);
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
    it("stakes one peuple", async () => {
      await buyAndStake(holder_1, ether(1));
    });
    it("rejects too small amount", async () => {
      await expect(stakePeuple(holder_1, ether(1).sub(1))).to.be.rejectedWith(
        Error
      );
    });
    describe("when first holder buys and stakes one billion peuple for one month", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
      });
      describe("when a thousand cake rewards distributed after 31 days", () => {
        beforeEach(async () => {
          await days(31);
          await sendCakeRewards(oneThousand);
        });
        it("receives rewards", async () => {
          const rewards = await staking.connect(holder_1).computeRewards(0);
          await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          const withdrawn = await peuple.balanceOf(holder_1.address);
          expect(rewards).to.equal(withdrawn).to.equal(oneBillion);
        });
        describe("two days later, when a hundred cake rewards is distributed", () => {
          beforeEach(async () => {
            await days(2);
            await sendCakeRewards(ether(100));
          });
          it("does NOT receives rewards", async () => {
            const rewards = await staking
              .connect(holder_1)
              .computeWithdrawableDividendsAndRewards(0);
            expect(rewards).to.equal(oneBillion);
          });
          it("releases unclaimable rewards when unstaking", async () => {
            await buyAndStake(holder_2, oneBillion);
            await staking.connect(holder_1).unstake(0);
            await days(2);
            await staking.createNewBlock();
            const rewards = await staking.connect(holder_2).computeRewards(0);
            expect(rewards).to.equal(oneMillion.mul(100));
          });
          describe("when first holder withdraws", () => {
            beforeEach(async () => {
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
            });
            describe("two days later, when a hundred cake rewards is distributed", () => {
              beforeEach(async () => {
                await days(2);
                await sendCakeRewards(ether(100));
              });
              it("does NOT receives rewards", async () => {
                const rewards = await staking
                  .connect(holder_1)
                  .computeDividendsAndRewards(0);
                expect(rewards).to.equal(oneBillion);
              });
              it("releases unclaimable rewards when unstaking", async () => {
                await buyAndStake(holder_2, oneBillion);
                await staking.connect(holder_1).unstake(0);
                await days(2);
                await staking.createNewBlock();
                const rewards = await staking
                  .connect(holder_2)
                  .computeRewards(0);
                expect(rewards).to.equal(oneMillion.mul(200));
              });
            });
          });
        });
      });
      describe("for one thousand cake dividends", () => {
        beforeEach(async () => {
          await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
          await days(2);
          await createNewBlock();
        });
        it("redistributes dividends to holder", async () => {
          const s = staking.connect(holder_1);
          const dividends = await s.computeDividends(0);
          const withdrawable = await s.computeWithdrawableDividendsAndRewards(
            0
          );
          await s.withdrawDividendsAndRewards(0);
          const withdrawn = await peuple.balanceOf(holder_1.address);
          expect(dividends)
            .to.equal(withdrawable)
            .to.equal(withdrawn)
            .to.equal(oneBillion);
          expect(await s.computeWithdrawableDividendsAndRewards(0)).to.equal(0);
        });
        it("can only withdraw dividends ONCE", async () => {
          await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          const balance = await peuple.balanceOf(holder_1.address);
          expect(balance).to.equal(oneBillion);
        });
        it("can NOT unstake", async () => {
          await staking.connect(holder_1).unstake(0);
          const balance = await peuple.balanceOf(holder_1.address);
          expect(balance).to.equal(0);
        });
        describe("when holder has withdrawn rewards and dividends", () => {
          beforeEach(async () => {
            await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          });
          describe("for one thousand cake dividends", () => {
            beforeEach(async () => {
              await cake
                .connect(cakeOwner)
                .transfer(staking.address, oneThousand);
              await days(2);
              await createNewBlock();
            });
            it("holder can withdraw dividends", async () => {
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
              const balance = await peuple.balanceOf(holder_1.address);
              expect(balance).to.equal(oneBillion.mul(2));
            });
          });
        });
        describe("after more than one month", () => {
          beforeEach(async () => {
            await days(31);
          });
          it("can unstake", async () => {
            await staking.connect(holder_1).unstake(0);
            const balance = await peuple.balanceOf(holder_1.address);
            expect(balance).to.equal(oneBillion.mul(2));
            expect(await staking.currentTotalStake()).to.equal(0);
            expect(await staking.currentTotalPonderedStake()).to.equal(0);
            expect(await peuple.balanceOf(staking.address)).to.equal(0);
          });
          it("removes unstaked from staked list", async () => {
            await staking.connect(holder_1).unstake(0);
            await expect(
              staking.connect(holder_1).holderStakes(holder_1.address, 0)
            ).to.be.rejectedWith(Error);
          });
          describe("after withdrawing dividends", () => {
            beforeEach(async () => {
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
            });
            it("can unstake", async () => {
              await staking.connect(holder_1).unstake(0);
              const balance = await peuple.balanceOf(holder_1.address);
              expect(balance).to.equal(oneBillion.mul(2));
            });
          });
          describe("when buy and stake one million", () => {
            beforeEach(async () => {
              await buyAndStake(holder_1, oneMillion);
            });
            it("can unstake first stake", async () => {
              await staking.connect(holder_1).unstake(0);
              const balance = await peuple.balanceOf(holder_1.address);
              expect(balance).to.equal(oneBillion.mul(2));
              await expect(
                staking.connect(holder_1).holderStakes(holder_1.address, 1)
              ).to.be.rejectedWith(Error);
              const stake = await staking
                .connect(holder_1)
                .holderStakes(holder_1.address, 0);
              expect(stake.amount).to.equal(oneMillion);
            });
          });
        });
      });
      it("redistributes all peuple rewards to holder", async () => {
        await sendPeupleRewards(oneBillion, 2);
        const rewards = await staking.connect(holder_1).computeRewards(0);
        expect(rewards).to.equal(oneBillion);
      });
      describe("when 1 thousand cake reward is sent two days later", () => {
        beforeEach(async () => {
          await days(2);
          await sendCakeRewards(oneThousand);
        });
        it("redistributes all cake rewards to holder", async () => {
          expect(await staking.connect(holder_1).computeRewards(0)).to.equal(
            oneBillion
          );
        });
        describe("when 1 thousand cake reward is sent two days later AGAIN", () => {
          beforeEach(async () => {
            await days(2);
            await sendCakeRewards(oneThousand);
          });
          it("redistributes all cake rewards to holder", async () => {
            expect(await staking.connect(holder_1).computeRewards(0)).to.equal(
              oneBillion.mul(2)
            );
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
            .computeDividends(0);
          const dividends_2 = await staking
            .connect(holder_2)
            .computeDividends(0);
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

          const rewards_1 = await staking.connect(holder_1).computeRewards(0);
          const rewards_2 = await staking.connect(holder_2).computeRewards(0);
          expect(rewards_2.gt(rewards_1)).to.be.true;
          const bonus = await staking.bonusForTwoMonthStaking();
          expect(rewards_2).to.equal(
            rewards_1.add(rewards_1.mul(bonus).div(100))
          );
        });
        it("can set bonus rate", async () => {
          await staking.connect(stakingOwner).setBonusForTwoMonthStaking(100);
          expect(await staking.bonusForTwoMonthStaking()).to.equal(100);
        });
        it("can't set bonus rate higher than 100%", async () => {
          await expect(
            staking.connect(stakingOwner).setBonusForTwoMonthStaking(101)
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

          const rewards_1 = await staking.connect(holder_1).computeRewards(0);
          const rewards_2 = await staking.connect(holder_2).computeRewards(0);
          expect(rewards_2.gt(rewards_1)).to.be.true;
          const bonus = await staking.bonusForThreeMonthStaking();
          expect(rewards_2).to.equal(
            rewards_1.add(rewards_1.mul(bonus).div(100))
          );
          expect(rewards_2).to.equal(oneThousand.mul(1_000_000).mul(2).div(3));
          expect(rewards_1).to.equal(oneThousand.mul(1_000_000).mul(1).div(3));
        });
        it("can set bonus rate", async () => {
          await staking.connect(stakingOwner).setBonusForThreeMonthStaking(200);
          expect(await staking.bonusForThreeMonthStaking()).to.equal(200);
        });
        it("can't set bonus rate higher than 200%", async () => {
          await expect(
            staking.connect(stakingOwner).setBonusForThreeMonthStaking(201)
          ).to.be.rejectedWith(Error);
        });
      });
    });
    it("handles staking and unstaking, twice", async () => {
      // ONCE
      await buyAndStake(holder_1, oneBillion);
      await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
      await days(2);
      await createNewBlock();
      await days(30);
      await staking.connect(holder_1).unstake(0);
      expect(await staking.currentTotalStake()).to.equal(0);
      expect(await peuple.balanceOf(holder_1.address)).to.equal(
        oneBillion.mul(2)
      );

      // TWICE
      await stakePeuple(holder_1, oneBillion, 1);
      await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
      await days(2);
      await createNewBlock();
      expect(
        await staking.connect(holder_1).computeDividendsAndRewards(0)
      ).to.equal(oneBillion);
      await days(30);
      await staking.connect(holder_1).unstake(0);
      expect(await peuple.balanceOf(holder_1.address)).to.equal(
        oneBillion.mul(3)
      );
    });
    describe("when holder with social bonus buys and stakes for one month and for one thousand cake dividends after 30 days", () => {
      beforeEach(async () => {
        await staking
          .connect(stakingOwner)
          .setHolderSocialBonus(holder_1.address, 100);
        await buyAndStake(holder_1, oneBillion);
        await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
        await days(2);
        await createNewBlock();
        await days(30);
      });
      it("can unstake", async () => {
        await staking.connect(holder_1).unstake(0);
        expect(await staking.currentTotalPonderedStake()).to.equal(0);
      });
    });
    describe("when holder buys and stakes for one month and has social bonus and for one thousand cake dividends after 30 days", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
        await staking
          .connect(stakingOwner)
          .setHolderSocialBonus(holder_1.address, 100);
        await cake.connect(cakeOwner).transfer(staking.address, oneThousand);
        await days(2);
        await createNewBlock();
        await days(30);
      });
      it("can unstake", async () => {
        await staking.connect(holder_1).unstake(0);
        expect(await staking.currentTotalPonderedStake()).to.equal(0);
      });
    });
    describe("when holder buys and stakes for two months, after 61 days", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion, 2);
        await days(61);
      });
      it("can unstake", async () => {
        await staking.connect(holder_1).unstake(0);
        expect(await staking.currentTotalPonderedStake()).to.equal(0);
      });
    });
    describe("when holder buys and stakes twice, after 31 days", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
        await buyAndStake(holder_1, oneBillion);
        await days(31);
      });
      it("can unstake all", async () => {
        await staking.connect(holder_1).unstake(0);
        await staking.connect(holder_1).unstake(0);
        expect(await staking.currentTotalPonderedStake()).to.equal(0);
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
        const dividends_1 = await staking.connect(holder_1).computeDividends(0);
        const dividends_2 = await staking.connect(holder_1).computeDividends(0);
        expect(dividends_1).to.equal(dividends_2).to.equal(oneBillion.div(2));
      });
      it("redistributes cake rewards evenly", async () => {
        await days(2);
        await sendCakeRewards(oneThousand);
        const rewards_1 = await staking.connect(holder_1).computeRewards(0);
        const rewards_2 = await staking.connect(holder_1).computeRewards(0);
        expect(rewards_1).to.equal(rewards_2).to.equal(oneBillion.div(2));
      });
      describe("when first holder has higher social bonus", () => {
        beforeEach(async () => {
          await staking
            .connect(stakingOwner)
            .setHolderSocialBonus(holder_1.address, 100);
        });
        it("redistributes more rewards to first holder", async () => {
          await days(2);
          await sendCakeRewards(oneThousand);
          const rewards_1 = await staking.connect(holder_1).computeRewards(0);
          const rewards_2 = await staking.connect(holder_2).computeRewards(0);
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
              .setHolderSocialBonus(holder_1.address, 0);
          });
          it("still redistributes more rewards to first holder", async () => {
            const rewards_1 = await staking.connect(holder_1).computeRewards(0);
            const rewards_2 = await staking.connect(holder_2).computeRewards(0);
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

    describe("when single holder buys and stakes one billion", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
      });
      const blocks = 80;
      describe(`when ${blocks} blocks with dividends are created`, () => {
        beforeEach(async () => {
          for await (let i of range(0, blocks)) {
            await cake.connect(cakeOwner).transfer(staking.address, ether(10));
            await days(2);
            await createNewBlock();
          }
        });
        it("runs out of gas when computing dividends", async () => {
          await expect(
            staking.connect(holder_1).computeDividends(0)
          ).to.be.rejectedWith(Error);
        });
        describe("when tried to withdraw once", () => {
          beforeEach(async () => {
            await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          });
          it("computes dividends", async () => {
            const dividends = await staking
              .connect(holder_1)
              .computeDividends(0);
            expect(dividends).to.equal(oneMillion.mul(blocks).mul(10));
          });
        });
      });
      describe(`when ${blocks} blocks with rewards are created`, () => {
        beforeEach(async () => {
          await days(31);
          await sendPeupleRewards(oneBillion);
          await createNewBlock();
          for await (let i of range(0, blocks)) {
            await sendPeupleRewards(oneMillion.mul(10), 2);
          }
        });
        it("runs out of gas when computing rewards", async () => {
          await expect(
            staking.connect(holder_1).computeRewards(0)
          ).to.be.rejectedWith(Error);
        });
        describe("when tried to withdraw once", () => {
          beforeEach(async () => {
            await staking.connect(holder_1).withdrawDividendsAndRewards(0);
          });
          it("computes rewards", async () => {
            const rewards = await staking.connect(holder_1).computeRewards(0);
            expect(rewards).to.equal(oneBillion);
          });
        });
      });
      describe("when second holder buys and stakes one billion, but first holder has better social score", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion);
          await staking
            .connect(stakingOwner)
            .setHolderSocialBonus(holder_1.address, 100);
        });
        describe("when one billion peuple reward received", () => {
          beforeEach(async () => {
            await sendPeupleRewards(oneBillion, 2);
          });
          describe("when first holder withdraws", () => {
            beforeEach(async () => {
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
            });
            describe("when another billion peuple reward received", () => {
              beforeEach(async () => {
                await sendPeupleRewards(oneBillion, 2);
              });
              it("precomputes rewards with social bonus", async () => {
                const rewards_1 = await staking
                  .connect(holder_1)
                  .computeRewards(0);
                expect(rewards_1).to.equal(
                  BigNumber.from("1333333333333333333333333332") //  oneBillion.mul(2).mul(2).div(3)
                );
                const rewards_2 = await staking
                  .connect(holder_2)
                  .computeRewards(0);
                expect(rewards_2).to.equal(oneBillion.mul(2).div(3));
              });
            });
          });
          it("withdraws rewards with social bonus", async () => {
            const rewards_1 = await staking.connect(holder_1).computeRewards(0);
            await staking.connect(holder_1).withdrawDividendsAndRewards(0);
            const withdrawn_1 = await peuple.balanceOf(holder_1.address);
            const rewards_2 = await staking.connect(holder_2).computeRewards(0);
            await staking.connect(holder_2).withdrawDividendsAndRewards(0);
            const withdrawn_2 = await peuple.balanceOf(holder_2.address);
            expect(rewards_1)
              .to.equal(withdrawn_1)
              .to.equal(oneBillion.mul(2).div(3));
            expect(rewards_2).to.equal(withdrawn_2).to.equal(oneBillion.div(3));
          });
          describe("when first holder gets his social score back to zero before another block is created", () => {
            beforeEach(async () => {
              await staking
                .connect(stakingOwner)
                .setHolderSocialBonus(holder_1.address, 0);
              await sendPeupleRewards(oneBillion, 2);
            });
            it("withdraws rewards with social bonus", async () => {
              const rewards_1 = await staking
                .connect(holder_1)
                .computeRewards(0);
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
              const withdrawn_1 = await peuple.balanceOf(holder_1.address);
              const rewards_2 = await staking
                .connect(holder_2)
                .computeRewards(0);
              await staking.connect(holder_2).withdrawDividendsAndRewards(0);
              const withdrawn_2 = await peuple.balanceOf(holder_2.address);
              expect(rewards_1)
                .to.equal(withdrawn_1)
                .to.equal(oneBillion.mul(2).div(3).add(oneBillion.div(2)));
              expect(rewards_2)
                .to.equal(withdrawn_2)
                .to.equal(oneBillion.div(3).add(oneBillion.div(2)));
            });
          });
        });
      });
    });
    describe("when single holder buys one billion and stakes it for 3 months", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion, 3);
      });
      describe("when second holder buys and stakes one billion for one month only", () => {
        beforeEach(async () => {
          await buyAndStake(holder_2, oneBillion);
        });
        describe("when one billion peuple reward received", () => {
          beforeEach(async () => {
            await sendPeupleRewards(oneBillion, 2);
          });
          describe("when first holder withdraws", () => {
            beforeEach(async () => {
              await staking.connect(holder_1).withdrawDividendsAndRewards(0);
            });
            describe("when another billion peuple reward received", () => {
              beforeEach(async () => {
                await sendPeupleRewards(oneBillion, 2);
              });
              it("withdraws rewards with time bonus", async () => {
                const rewards_1 = await staking
                  .connect(holder_1)
                  .computeRewards(0);
                await staking.connect(holder_1).withdrawDividendsAndRewards(0);
                const withdrawn_1 = await peuple.balanceOf(holder_1.address);
                const rewards_2 = await staking
                  .connect(holder_2)
                  .computeRewards(0);
                await staking.connect(holder_2).withdrawDividendsAndRewards(0);
                const withdrawn_2 = await peuple.balanceOf(holder_2.address);
                expect(rewards_1)
                  .to.equal(withdrawn_1)
                  .to.equal(BigNumber.from("1333333333333333333333333332")); // oneBillion.mul(2).mul(2).div(3)
                expect(rewards_2)
                  .to.equal(withdrawn_2)
                  .to.equal(oneBillion.mul(2).div(3));
              });
            });
          });
        });
      });
    });
    describe(`when bought and staked one billion, twice`, () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion);
        await buyAndStake(holder_1, oneBillion);
      });
    });

    describe(".restake()", () => {
      describe("when single holder buys and stakes one billion", () => {
        beforeEach(async () => {
          await buyAndStake(holder_1, oneBillion);
        });
        it("can NOT restake after 29 days only", async () => {
          await days(29);
          await expect(
            staking.connect(holder_1).restake(0, 1)
          ).to.be.rejectedWith(Error);
        });
        describe("when another holder buys and stakes one billion also", () => {
          beforeEach(async () => {
            await buyAndStake(holder_2, oneBillion);
          });
          describe("when one billion peuple rewards received", () => {
            beforeEach(async () => {
              await sendPeupleRewards(oneBillion, 2);
            });
            describe("after 31 days", () => {
              beforeEach(async () => {
                await days(31);
              });
              describe("when first holder restakes for 3 months", () => {
                beforeEach(async () => {
                  await staking.connect(holder_1).restake(0, 3);
                });
                it("computes rewards with relevant bonus for each period", async () => {
                  await sendPeupleRewards(oneBillion, 2);
                  const computed_1 = await staking
                    .connect(holder_1)
                    .computeRewards(0);
                  await staking
                    .connect(holder_1)
                    .withdrawDividendsAndRewards(0);
                  const withdrawn_1 = await peuple.balanceOf(holder_1.address);
                  expect(computed_1)
                    .to.equal(withdrawn_1)
                    .to.equal(oneBillion.div(2).add(oneBillion.mul(2).div(3)));
                });
              });
            });
          });
        });
        describe("after single block of 31 days and one billion peuple rewards", () => {
          beforeEach(async () => {
            await sendPeupleRewards(oneBillion, 31);
          });
          it("can restake", async () => {
            await staking.connect(holder_1).restake(0, 1);
            await staking.connect(holder_1).unstake(0);
            expect(await peuple.balanceOf(holder_1.address)).to.equal(0);
          });
          describe("when restaking for 3 months", () => {
            beforeEach(async () => {
              await staking.connect(holder_1).restake(0, 3);
            });
            it("earns rewards with new time bonus", async () => {
              await buyAndStake(holder_2, oneBillion);
              await sendPeupleRewards(oneBillion, 2);
              const rewards_1 = await staking
                .connect(holder_1)
                .computeRewards(0);
              const rewards_2 = await staking
                .connect(holder_2)
                .computeRewards(0);
              expect(rewards_1).to.equal(
                oneBillion.add(oneBillion.mul(2).div(3))
              );
              expect(rewards_2).to.equal(oneBillion.div(3));
            });
          });
          describe("when another holder buys and stakes one billion also", () => {
            beforeEach(async () => {
              await buyAndStake(holder_2, oneBillion);
            });
            describe("when one billion peuple reward received", () => {
              beforeEach(async () => {
                await sendPeupleRewards(oneBillion, 2);
              });
              describe("when restaking for one month", () => {
                beforeEach(async () => {
                  await staking.connect(holder_1).restake(0, 1);
                });
                it("receives unclaimed rewards", async () => {
                  const computed = await staking
                    .connect(holder_1)
                    .computeRewards(0);
                  await staking
                    .connect(holder_1)
                    .withdrawDividendsAndRewards(0);
                  const withdrawn = await peuple.balanceOf(holder_1.address);
                  expect(computed)
                    .to.equal(withdrawn)
                    .to.equal(oneBillion.add(oneBillion.div(2)));
                });
              });
            });
          });
        });
      });
      describe("when first holder stakes one billion for 2 months, second holder for 1 month", () => {
        beforeEach(async () => {
          await buyAndStake(holder_1, oneBillion, 2);
          await buyAndStake(holder_2, oneBillion, 1);
        });
        describe("after single block of 61 days and one billion peuple rewards", () => {
          beforeEach(async () => {
            await sendPeupleRewards(oneBillion, 61);
          });
          describe("when one billion peuple reward received", () => {
            beforeEach(async () => {
              await sendPeupleRewards(oneBillion, 2);
            });
            describe("when 2 months bonus set to zero", () => {
              beforeEach(async () => {
                await staking
                  .connect(stakingOwner)
                  .setBonusForTwoMonthStaking(0);
              });
              it("gives partial unclaimed rewards to first staker for restaking", async () => {
                await staking.connect(holder_1).restake(0, 2);
                await sendPeupleRewards(oneBillion, 2);
                const computed = await staking
                  .connect(holder_1)
                  .computeDividendsAndRewards(0);
                expect(computed).to.equal(
                  oneBillion.add(oneBillion.mul(3).div(5))
                );
              });
            });
          });
        });
      });
    });
  });

  describe(".setSocialBonusBatch()", () => {
    beforeEach(async () => {
      const p = peuple.connect(peupleOwner);
      await p.setCAKERewardsFee(0);
      await p.setLiquidityFee(0);
      await p.setMarketingFee(0);
    });
    describe("when four holders buy and stake", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion, 3);
        await buyAndStake(holder_2, oneBillion, 3);
        await buyAndStake(holder_3, oneBillion, 2);
        await buyAndStake(holder_4, oneBillion, 1);
      });
      it("can set multiple social bonuses", async () => {
        await staking.connect(stakingOwner).setSocialBonusBatch([
          { holderAddress: holder_1.address, socialBonus: 100 },
          { holderAddress: holder_2.address, socialBonus: 80 },
          { holderAddress: holder_3.address, socialBonus: 60 },
          { holderAddress: holder_4.address, socialBonus: 40 },
        ]);
        expect(await staking.getHolderSocialBonus(holder_1.address)).to.equal(
          100
        );
        expect(await staking.getHolderSocialBonus(holder_2.address)).to.equal(
          80
        );
        expect(await staking.getHolderSocialBonus(holder_3.address)).to.equal(
          60
        );
        expect(await staking.getHolderSocialBonus(holder_4.address)).to.equal(
          40
        );
      });
      it("returns processed count", async () => {
        const processedCount = await staking
          .connect(stakingOwner)
          .callStatic.setSocialBonusBatch([
            { holderAddress: holder_1.address, socialBonus: 100 },
            { holderAddress: holder_2.address, socialBonus: 80 },
            { holderAddress: holder_3.address, socialBonus: 60 },
            { holderAddress: holder_4.address, socialBonus: 40 },
          ]);
        expect(processedCount).to.equal(4);
      });
    });
  });

  describe(".stakeDividendsAndRewards()", () => {
    beforeEach(async () => {
      const p = peuple.connect(peupleOwner);
      await p.setCAKERewardsFee(0);
      await p.setLiquidityFee(0);
      await p.setMarketingFee(0);
    });
    describe("when single holder buys and stakes", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion, 3);
      });
      describe("when one billion rewards received", () => {
        beforeEach(async () => {
          await sendPeupleRewards(oneBillion, 2);
        });
        it("can restake dividends and rewards", async () => {
          await staking.connect(holder_1).stakeDividendsAndRewards(0);
          const result = await staking.computeHolderStakeInfo(
            holder_1.address,
            0
          );
          expect(result.stakeAmount)
            .to.equal(await staking.currentTotalStake())
            .to.equal(oneBillion.mul(2));
          expect(result.ponderedStakeAmount)
            .to.equal(await staking.currentTotalPonderedStake())
            .to.equal(oneBillion.mul(4));
          expect(result.claimableRewards).to.equal(oneBillion);
          expect(result.withdrawn).to.equal(oneBillion);
        });
      });
    });
  });

  describe(".decommission()", () => {
    beforeEach(async () => {
      const p = peuple.connect(peupleOwner);
      await p.setCAKERewardsFee(0);
      await p.setLiquidityFee(0);
      await p.setMarketingFee(0);
    });
    describe("when single holder buys and stakes", () => {
      beforeEach(async () => {
        await buyAndStake(holder_1, oneBillion, 3);
      });
      describe("when one billion rewards received", () => {
        beforeEach(async () => {
          await sendPeupleRewards(oneBillion, 2);
        });
        it("can not empty staking wallet", async () => {
          await expect(
            staking.connect(stakingOwner).emptyWholeWallet(holder_4.address)
          ).to.be.rejectedWith(Error);
        });
        it("can not decommission with wrong validation message", async () => {
          await expect(
            staking
              .connect(stakingOwner)
              .decommission("wrong validation message")
          ).to.be.rejectedWith(Error);
        });
        it("can not be decommissioned by non-owner", async () => {
          await expect(
            staking.connect(holder_1).decommission("YeSS, I aM SuRe !!!")
          ).to.be.rejectedWith(Error);
        });
        describe("when decommissioned", () => {
          beforeEach(async () => {
            await staking
              .connect(stakingOwner)
              .decommission("YeSS, I aM SuRe !!!");
          });
          it("can not empty staking wallet", async () => {
            await expect(
              staking.connect(stakingOwner).emptyWholeWallet(holder_4.address)
            ).to.be.rejectedWith(Error);
          });
          it("can not be decommission twice", async () => {
            await expect(
              staking.connect(stakingOwner).decommission("YeSS, I aM SuRe !!!")
            ).to.be.rejectedWith(Error);
          });
          it("allows holders to unstake even if staking period not finished", async () => {
            await staking.connect(holder_1).unstake(0);
            expect(await peuple.balanceOf(holder_1.address)).to.equal(
              oneBillion.mul(2)
            );
          });
          it("can not cancel decommission with wrong validation message", async () => {
            await expect(
              staking
                .connect(stakingOwner)
                .cancelDecommission("wrong validation message")
            ).to.be.rejectedWith(Error);
          });
          it("can not cancel decommission by non-owner", async () => {
            await expect(
              staking
                .connect(holder_1)
                .cancelDecommission("YeSS, I aM SuRe !!!")
            ).to.be.rejectedWith(Error);
          });
          describe("when decommission canceled", () => {
            beforeEach(async () => {
              await staking
                .connect(stakingOwner)
                .cancelDecommission("YeSS, I aM SuRe !!!");
            });
            it("can not empty staking wallet", async () => {
              await expect(
                staking.connect(stakingOwner).emptyWholeWallet(holder_4.address)
              ).to.be.rejectedWith(Error);
            });
            it("can not unstake before staking period is over anymore", async () => {
              await staking.connect(holder_1).unstake(0);
              expect(await peuple.balanceOf(holder_1.address)).to.equal(0);
            });
            it("can not cancel decommission again", async () => {
              await expect(
                staking
                  .connect(stakingOwner)
                  .cancelDecommission("YeSS, I aM SuRe !!!")
              ).to.be.rejectedWith(Error);
            });
          });
          describe("after 120 days", () => {
            beforeEach(async () => {
              await days(120);
            });
            it("can empty staking wallet", async () => {
              await staking
                .connect(stakingOwner)
                .emptyWholeWallet(holder_4.address);
              expect(await peuple.balanceOf(holder_4.address)).to.equal(
                oneBillion.mul(2)
              );
              expect(await peuple.balanceOf(staking.address)).to.equal(0);
              expect(await staking.currentTotalStake()).to.equal(0);
              expect(await staking.currentTotalPonderedStake()).to.equal(0);
              expect(await staking.currentTotalOwnedPeuple()).to.equal(0);
            });
            it("can not empty whole wallet when not owner", async () => {
              await expect(
                staking.connect(holder_4).emptyWholeWallet(holder_4.address)
              ).to.be.rejectedWith(Error);
            });
          });
        });
      });
    });
  });
});
