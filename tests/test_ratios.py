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

    previousDebt = comet.borrowBalanceOf(strategy)
    tx = strategy.harvest({"from": gov})
    assert previousDebt > comet.borrowBalanceOf(strategy)
    print_status(strategy, vault, comet.baseScale())

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

    chain.sleep(1)
    previousDebt = comet.borrowBalanceOf(strategy)
    strategy.harvest({"from": gov})
    print_status(strategy, vault, comet.baseScale())

    #account for potential rounding errors
    assert comet.borrowBalanceOf(strategy) < 10
    assert token.balanceOf(strategy) == 0
    assert strategy.balanceOfCollateral() > 0  # want is deposited as collateral

    print(f"TotalAssets:{strategy.estimatedTotalAssets()}")
    print(f"Collateral: {strategy.balanceOfCollateral()}")
    print(f"Value of users holding {vault.balanceOf(token_whale) * vault.pricePerShare() / (10**vault.decimals())}")
    

def print_status(strat, v, decimal):
    print(f"Info fpr {strat.name()}")
    decimals = 10 ** v.decimals()
    print(f"Estimated strat assets : {strat.estimatedTotalAssets()/decimals}")
    print(f"made up of {strat.balanceOfWant()/decimals} loose want")
    print(f"made up of {strat.balanceOfCollateral()/decimals} of Collateral")
    #print(f"{strat.getRewardsOwed()} in owed reward")
    print(f"made up of {strat.rewardsInWant()/decimals} rewards in want")
    print(f"made up of {strat.balanceOfDebt()/(decimal)} of debt owed")
    print(f"made up of {strat.balanceOfDepositer()/(decimal)} of yvault assets")
    print(f"For a total base token owed bal of {strat.baseTokenOwedBalance()/(decimal)}")
