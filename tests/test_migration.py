import pytest
from brownie import chain, Wei, reverts

def test_migration(
    vault,
    strategy,
    Strategy,
    gov,
    token,
    token_whale,
    borrow_token,
    borrow_whale,
    depositer,
    cloner,
    strategist,
    amount,
    comet,
    ethToWantFee
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(60 * 60 * 12)

    strategy.harvest({"from": gov})
    chain.sleep(60 * 60 * 24 * 2)
    chain.mine(1)

    # Deploy new Strategy and migrate
    strategy2 = Strategy.at(
        cloner.cloneCompV3LenderBorrower(
            vault,
            strategist,
            strategist,
            strategist,
            comet,
            ethToWantFee,
            "name",
        ).return_value["newStrategy"]
    )

    old_debt_ratio = vault.strategies(strategy).dict()["debtRatio"]

    chain.sleep(1)
    vault.migrateStrategy(strategy, strategy2, {"from": gov})
    vault.updateStrategyDebtRatio(strategy2, old_debt_ratio, {"from": gov})
    chain.sleep(1)
    strategy2.harvest({"from": gov})

    assert vault.strategies(strategy).dict()["totalDebt"] == 0
    assert vault.strategies(strategy2).dict()["totalDebt"] > 0
    assert vault.strategies(strategy2).dict()["debtRatio"] == old_debt_ratio
