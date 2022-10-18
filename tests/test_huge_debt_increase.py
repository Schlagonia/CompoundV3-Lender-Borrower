import pytest
from brownie import chain, Contract


def test_huge_debt(vault, strategy, gov, token, token_whale, amount, comet):
    prev_balance = token.balanceOf(token_whale)
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount * 2, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    prev_debt = comet.borrowBalanceOf(strategy.address)
    print(f"T=0 totalDebt: {prev_debt}")

    # After first investment sleep for aproximately a month
    chain.sleep(60 * 60 * 24 * 30)
    chain.mine(1)
    new_debt =  comet.borrowBalanceOf(strategy.address)
    print(f"T=365 totalDebt: {new_debt}")
    assert new_debt > prev_debt

    # Test that there is no loss
    strategy.harvest({"from": gov})
    assert vault.strategies(strategy).dict()["totalLoss"] == 0

    #let profit unlock
    chain.sleep(60 *60 *6)
    vault.withdraw( {"from": token_whale})

    # we are currently in a profitable scenario so there is no loss
    print(f"diff {prev_balance-token.balanceOf(token_whale)}")
    assert token.balanceOf(token_whale) - prev_balance > 0

