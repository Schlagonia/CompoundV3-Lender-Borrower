import pytest
from brownie import chain


def test_revoke_with_profit(
    token,
    vault,
    strategy,
    token_whale,
    gov,
    RELATIVE_APPROX,
    borrow_token,
    borrow_whale,
    yvault,
    comet,
    amount
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    # Send some profit to yvault
    chain.sleep(60 * 60 *12)
    vault.revokeStrategy(strategy, {"from": gov})
    strategy.harvest({"from": gov})
    assert vault.strategies(strategy).dict()["totalGain"] > 0
    assert vault.strategies(strategy).dict()["totalDebt"] <= 1
