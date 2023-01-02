import pytest
from brownie import chain, Contract


def test_live_vault(live_vault, strategy, gov, token, token_whale, amount, comet, cloner,
    strategist, rewards, keeper, ethToWantFee, depositer, baseToken
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
    current_dr = vault.debtRatio()
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
