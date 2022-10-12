import pytest
from brownie import chain, Wei, Contract, accounts, ZERO_ADDRESS


def test_rate_above_optimal(
    vault, strategy, gov, token, token_whale, borrow_whale, borrow_token, amount, comet, bal_vault
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    print(f"current Borrow rate: {strategy.getBorrowApr(0)/1e18}")
    print(f"current reward rate: {strategy.getRewardAprForBorrowBase(0)/1e18}")

    strategy.harvest({"from": gov})
    chain.sleep(1)
    assert comet.borrowBalanceOf(strategy) > 0
    # This will increase the rate to > 100%
    increase_interest(borrow_token, token, bal_vault, comet)
    print(f"current Borrow rate: {strategy.getBorrowApr(0)/1e18}")
    print(f"current reward rate: {strategy.getRewardAprForBorrowBase(0)/1e18}")

    chain.sleep(1)    
    assert strategy.tendTrigger(0) == True
    strategy.tend({"from": gov})
    assert comet.borrowBalanceOf(strategy) == 0
    chain.sleep(1)    
    print(f"current Borrow rate: {strategy.getBorrowApr(0)/1e18}")
    print(f"current reward rate: {strategy.getRewardAprForBorrowBase(0)/1e18}")

    strategy.harvest({"from": gov})
    assert comet.borrowBalanceOf(strategy) == 0


def increase_interest(bToken, t, whale, com):
    toSupply = 2000
    t.approve(com.address, 2 ** 256 - 1, {"from":whale})
    com.supply(t, toSupply, {"from":whale})
    com.withdraw(bToken, 30000000, {"from":whale})
    
