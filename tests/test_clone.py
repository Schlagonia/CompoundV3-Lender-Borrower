import pytest
from brownie import chain, Wei, reverts, Contract

def test_clone(
    vault,
    strategy,
    strategist,
    rewards,
    keeper,
    gov,
    token,
    token_whale,
    borrow_whale,
    baseToken,
    comet,
    ethToWantFee,
    cloner,
    depositer,
    weth,
    comp
):

    clone_tx = cloner.cloneCompV3LenderBorrower(
        vault,
        strategist,
        rewards,
        keeper,
        comet,
        ethToWantFee,
        "StrategyCompLender" + token.symbol() + "Borrower" + baseToken.symbol(),
    )
    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.return_value["newStrategy"], strategy.abi
    )
    cloned_depositer = Contract.from_abi(
        "Depositer", clone_tx.return_value["newDepositer"], depositer.abi
    )
    
    # should fail due to already initialized
    with reverts():
        cloned_strategy.initialize(vault, comet, ethToWantFee, cloned_depositer, "NameRevert", {"from": gov})

    with reverts():
        cloned_depositer.initialize(comet, {"from": gov})
    
    with reverts():
        cloned_depositer.setStrategy(cloned_strategy.address, {"from": gov})

    with reverts():
        cloned_depositer.cloneDepositer(comet, {"from":gov})
    
    if cloned_strategy.baseToken() == weth:
        cloned_depositer.setPriceFeeds(
            "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
            depositer.rewardTokenPriceFeed(),
            {"from": gov}
        )
        # set reward price feed to be comp/eth
        cloned_strategy.setPriceFeed(
            comp,
            "0x1B39Ee86Ec5979ba5C322b826B3ECb8C79991699",
            {"from": strategy.strategist()},
        )
        # set want to non-scaled version
        bad_feed = Contract(comet.getAssetInfoByAddress(strategy.want())["priceFeed"])
        good_feed = bad_feed.stETHtoETHPriceFeed()
        cloned_strategy.setPriceFeed(
            strategy.want(),
            good_feed,
            {"from": strategy.strategist()},
        )

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(1 * (10 ** token.decimals()), {"from": token_whale})
    strategy = cloned_strategy

    #print_debug(cloned_depositer, strategy, comet)
    tx = strategy.harvest({"from": gov})

    #assert yvault.balanceOf(strategy) > 0
    #print_debug(cloned_depositer, strategy, comet)

    #print_strat_status(strategy, vault, comet.baseScale())
    # Sleep for 1 days
    chain.sleep(60 * 60 * 24)
    chain.mine(1)
 
    # Send some profit to yvETH
    #baseToken.transfer(yvault, 1_000 * (10 ** baseToken.decimals()), {"from": borrow_whale})
    comet.accrueAccount(strategy.address, {"from": gov})
    #print_strat_status(strategy, vault, comet.baseScale())
    # TODO: check profits before and after
    strategy.harvest({"from": gov})


    # We should have profit after getting some profit from comp
    assert vault.strategies(strategy).dict()["totalGain"] > 0
    assert vault.strategies(strategy).dict()["totalLoss"] == 0

    # Enough sleep for profit to be free
    chain.sleep(60 * 60 * 7)
    chain.mine(1)
    
    # so we send profits
    baseToken.transfer(cloned_strategy, 1_000e6, {"from": borrow_whale})
    vault.withdraw({"from": token_whale})


def test_clone_of_weth(
    weth_vault,
    strategy,
    strategist,
    rewards,
    keeper,
    gov,
    weth,
    weth_whale,
    interface,
    ethToWantFee,
    cloner,
    depositer
):  
    comet = interface.Comet("0xc3d688B66703497DAA19211EEdff47f25384cdc3")
    baseToken = Contract(comet.baseToken())

    clone_tx = cloner.cloneCompV3LenderBorrower(
        weth_vault,
        strategist,
        rewards,
        keeper,
        comet,
        3000,
        "StrategyCompLender" + weth.symbol() + "Borrower" + baseToken.symbol(),
    )
    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.return_value["newStrategy"], strategy.abi
    )
    cloned_depositer = Contract.from_abi(
        "Depositer", clone_tx.return_value["newDepositer"], depositer.abi
    )
    
    # should fail due to already initialized
    with reverts():
        cloned_strategy.initialize(weth_vault, comet, ethToWantFee, cloned_depositer, "NameRevert", {"from": gov})
    
    with reverts():
        cloned_depositer.initialize(comet, {"from": gov})

    with reverts():
        cloned_depositer.setStrategy(cloned_strategy.address, {"from": gov})

    with reverts():
        cloned_depositer.cloneDepositer(comet, {"from":gov})

    weth_vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})
    chain.sleep(1)
    weth.approve(weth_vault, 2 ** 256 - 1, {"from": weth_whale})
    weth_vault.deposit(10 * (10 ** weth.decimals()), {"from": weth_whale})
    strategy = cloned_strategy
    print_debug(cloned_depositer, strategy, comet)
    strategy.harvest({"from": gov})
    #assert yvault.balanceOf(strategy) > 0
    print_debug(cloned_depositer, strategy, comet)
    print_strat_status(strategy, weth_vault, comet.baseScale())
    # Sleep for 1 days
    chain.sleep(60 * 60 * 24)
    chain.mine(1)

    # TODO: check profits before and after
    strategy.harvest({"from": gov})
    print_debug(cloned_depositer, strategy, comet)

    # We should have profit
    assert weth_vault.strategies(strategy).dict()["totalGain"] > 0
    assert weth_vault.strategies(strategy).dict()["totalLoss"] == 0

    # Enough sleep for profit to be free
    chain.sleep(60 * 60 * 7)
    chain.mine(1)
    print_debug(cloned_depositer, strategy, comet)

    weth_vault.withdraw({"from": weth_whale})


def print_debug(dep, strategy, com):
    supply_balance = dep.cometBalance()
    totalDebt = com.borrowBalanceOf(strategy)
    decimal = 10 ** Contract(strategy.baseToken()).decimals()
    print(f"Strategy supply balance is: {supply_balance}")
    print(f"Strategy borrow value {supply_balance/decimal} vs {totalDebt/decimal}\n")

def print_strat_status(strat, v, decimal):
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
