import pytest
from brownie import chain, Contract, reverts


def test_live_vault(live_vault, strategy, depositer, gov, token, token_whale, amount, comet, cloner,
    strategist, rewards, keeper, ethToWantFee, baseToken, comp, weth
):
    vault = live_vault
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
            cloned_depositer.rewardTokenPriceFeed(),
            {"from": gov}
        )
        # set reward price feed to be comp/eth
        cloned_strategy.setPriceFeed(
            comp,
            "0x1B39Ee86Ec5979ba5C322b826B3ECb8C79991699",
            {"from": cloned_strategy.strategist()},
        )
        # set want to non-scaled version
        bad_feed = Contract(comet.getAssetInfoByAddress(cloned_strategy.want())["priceFeed"])
        good_feed = bad_feed.stETHtoETHPriceFeed()
        cloned_strategy.setPriceFeed(
            cloned_strategy.want(),
            good_feed,
            {"from": cloned_strategy.strategist()},
        )
    
    print(f"Base scale {comet.baseScale()}")
    print(f"Base index scale {comet.baseIndexScale()}")
    print(f"Reward APR {cloned_depositer.getNetRewardApr(0)}")
    print(f"Net borrow apr {cloned_depositer.getNetBorrowApr(0)}")
    current_dr = vault.debtRatio()
    if current_dr == 10_000:
        vault.updateStrategyDebtRatio(
            vault.withdrawalQueue(0),
            0,
            {"from": gov}
        )
    current_dr = vault.debtRatio()
    assert current_dr < 10_000
    vault.addStrategy(cloned_strategy, 10_000 - current_dr, 0, 2 ** 256 - 1, 0, {"from": gov})
    prev_balance = token.balanceOf(token_whale)
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount * 2, {"from": token_whale})

    chain.sleep(1)
    cloned_strategy.harvest({"from": gov})

    prev_debt = comet.borrowBalanceOf(cloned_strategy.address)
    print(f"T=0 totalDebt: {prev_debt}")

    # After first investment sleep for aproximately a day
    chain.sleep(60 * 60 * 24)
    chain.mine(1)
    new_debt =  comet.borrowBalanceOf(cloned_strategy.address)
    print(f"T=365 totalDebt: {new_debt}")
    assert new_debt > prev_debt

    # Test that there is no loss until withdrawal
    cloned_strategy.harvest({"from": gov})
    assert vault.strategies(cloned_strategy).dict()["totalLoss"] == 0

    chain.sleep(60 * 60 * 7)
    
    vault.withdraw({"from": token_whale})

    # we are currently in a profitable scenario so there is no loss
    print(f"diff {prev_balance-token.balanceOf(token_whale)}")
    assert token.balanceOf(token_whale) - prev_balance > 0
