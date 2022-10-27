from brownie import chain, reverts, Contract


def test_lev_ratios(
    vault,
    strategy,
    gov,
    token,
    token_whale,
    borrow_token,
    borrow_whale,
    depositer,
    comet,
    amount
):

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    targetLTV = strategy.targetLTVMultiplier()

    print_status(strategy, vault, comet.baseScale())
    # should revert with ratios > 90%
    with reverts():
        strategy.setStrategyParams(
            9_001,
            9_001,
            strategy.minToSell(),
            strategy.leaveDebtBehind(),
            strategy.maxGasPriceToTend(),
            {"from": strategy.strategist()},
        )
    # should revert if targetRatio > warningRatio
    with reverts():
        strategy.setStrategyParams(
            8_000,
            7_000,
            strategy.minToSell(),
            strategy.leaveDebtBehind(),
            strategy.maxGasPriceToTend(),
            {"from": strategy.strategist()},
        )

    # we reduce the target to half and set ratios just below current ratios
    strategy.setStrategyParams(
        targetLTV / 2,
        targetLTV / 1.01,
        strategy.minToSell(),
        strategy.leaveDebtBehind(),
        strategy.maxGasPriceToTend(),
        {"from": strategy.strategist()},
    )
    # to offset interest rates and be able to repay full debt (assuming we were able to generate profit before lowering acceptableCosts)
    #borrow_token.transfer(
    #    depositer, 10_000 * (10 ** borrow_token.decimals()), {"from": borrow_whale}
    #)
    previousDebt = comet.borrowBalanceOf(strategy)
    tx = strategy.harvest({"from": gov})
    assert previousDebt > comet.borrowBalanceOf(strategy)
    print_status(strategy, vault, 10**comet.baseScale())

    print_status(strategy, vault, comet.baseScale())
    # we reduce the target to half and set target ratio = 0
    strategy.setStrategyParams(
        0, 
        targetLTV / 3,  # trigger to set to rebalance
        strategy.minToSell(),
        strategy.leaveDebtBehind(),
        strategy.maxGasPriceToTend(),
        {"from": strategy.strategist()},
    )
    # to offset interest rates and be able to repay full debt (assuming we were able to generate profit before lowering acceptableCosts)
    #borrow_token.transfer(
    #    depositer, 10000 * (10 ** borrow_token.decimals()), {"from": borrow_whale}
    #)
    chain.slee(1)
    previousDebt = comet.borrowBalanceOf(strategy)
    strategy.harvest({"from": gov})
    print_status(strategy, vault, comet.baseScale())

    assert comet.borrowBalanceOf(strategy) == 0
    assert token.balanceOf(strategy) == 0
    assert strategy.balanceOfCollateral() > 0  # want is deposited as collateral
    # rounding
    # assert (
    #     strategy.estimatedTotalAssets()-aToken.balanceOf(strategy) < 3
    # )  # no debt, no investments
    print(f"TotalAssets:{strategy.estimatedTotalAssets()}")
    print(f"Collateral: {strategy.balanceOfCollateral()}")
    print(f"Value of users holding {vault.balanceOf(token_whale) * vault.pricePerShare() / (10**vault.decimals())}")
    #borrow_token.transfer(
    #    depositer, 1000 * (10 ** borrow_token.decimals()), {"from": borrow_whale}
    #)

    vault.withdraw({"from": token_whale})
    

def print_status(strat, v, decimal):
    print(f"Info fpr {strat.name()}")
    decimals = 10 ** v.decimals()
    print(f"Estimated strat assets : {strat.estimatedTotalAssets()/decimals}")
    print(f"made up of {strat.balanceOfWant()/decimals} loose want")
    print(f"made up of {strat.balanceOfCollateral()/decimals} of Collateral")
    #print(f"{strat.getRewardsOwed()} in owed reward")
    print(f"made up of {strat.rewardsInWant()/decimals} rewards in want")
    print(f"made up of {strat.balanceOfDebt()/(10**decimal)} of debt owed")
    print(f"made up of {strat.balanceOfDepositer()/(10**decimal)} of yvault assets")
    print(f"For a total base token owed bal of {strat.baseTokenOwedBalance()/(10**decimal)}")
