from brownie import chain
import pytest


def test_revoke_strategy_from_vault(
    token,
    vault,
    strategy,
    token_whale,
    gov,
    RELATIVE_APPROX,
    comet,
    depositer,
    amount
):

    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.revokeStrategy(strategy.address, {"from": gov})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    assert pytest.approx(token.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount



def test_revoke_strategy_from_strategy(
    token, vault, strategy, gov, token_whale, RELATIVE_APPROX, amount
):

    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.setEmergencyExit({"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(token.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount
