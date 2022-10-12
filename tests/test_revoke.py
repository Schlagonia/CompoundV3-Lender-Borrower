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
    yvault,
    borrow_token,
    borrow_whale,
):
    amount = 50_000 * (10 ** token.decimals())
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    vault.revokeStrategy(strategy.address, {"from": gov})

    # Send some profit to yvault to compensate losses, so the strat is able to repay full amount
    chain.sleep(60*60*24)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert (
        pytest.approx(
            comet.borrowBalanceOf(strategy) / (10 ** yvault.decimals()),
            rel=RELATIVE_APPROX,
        )
        == 0
    )
    assert (
        pytest.approx(
            strategy.balanceOfCollateral(strategy) / (10 ** vault.decimals()), rel=RELATIVE_APPROX
        )
        == 0
    )
    assert token.balanceOf(vault.address) >= amount


def test_revoke_strategy_from_strategy(
    token, vault, strategy, gov, token_whale, RELATIVE_APPROX
):
    amount = 50_000 * (10 ** token.decimals())
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    strategy.setEmergencyExit({"from": gov})
    strategy.harvest({"from": gov})
    assert pytest.approx(token.balanceOf(vault.address), rel=RELATIVE_APPROX) == amount
