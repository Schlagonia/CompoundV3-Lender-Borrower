from brownie import chain
import pytest

def test_direct_transfer_increments_estimated_total_assets(
    strategy, token, token_whale,
):
    initial = strategy.estimatedTotalAssets()
    amount = 10 * (10 ** token.decimals())
    token.transfer(strategy, amount, {"from": token_whale})
    assert strategy.estimatedTotalAssets() == initial + amount


def test_direct_transfer_increments_profits(vault, strategy, token, token_whale, gov, amount, RELATIVE_APPROX):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    initialProfit = vault.strategies(strategy).dict()["totalGain"]
    assert initialProfit == 0

    amount = 1 * (10 ** token.decimals())
    token.transfer(strategy, amount, {"from": token_whale})
    chain.sleep(10)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    #assert vault.strategies(strategy).dict()["totalGain"] >= initialProfit + amount
    assert pytest.approx(vault.strategies(strategy).dict()["totalGain"], rel=RELATIVE_APPROX) == amount


def test_borrow_token_transfer_sends_to_depositer(
    vault, strategy, token, token_whale, baseToken, borrow_whale, gov, amount
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})


    amount = 10 * (10 ** baseToken.decimals())
    baseToken.transfer(strategy, amount, {"from": borrow_whale})
    chain.sleep(1)

    strategy.harvest({"from": gov})
    assert baseToken.balanceOf(strategy) == 0


def test_borrow_token_transfer_increments(
    vault, depositer, strategy, token, token_whale, baseToken, borrow_whale, gov, amount
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    initialBalance = depositer.cometBalance()

    amount = 10 * (10 ** baseToken.decimals())
    baseToken.transfer(strategy, amount, {"from": borrow_whale})
    chain.sleep(1)

    strategy.harvest({"from": gov})
    assert depositer.cometBalance() > initialBalance


def test_borrow_token_transfer_increments_profits(
    vault, strategy, token, token_whale, baseToken, borrow_whale, gov, amount
):
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    amount = 10 * (10 ** baseToken.decimals())
    baseToken.transfer(strategy, amount, {"from": borrow_whale})
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})

    chain.sleep(60)  # wait a minute!
    chain.mine(1)

    strategy.harvest({"from": gov})
    # account for fees and slippage - our profit should be at least 95% of the transfer in want
    assert vault.strategies(strategy).dict()["totalGain"] > 0

def test_deposit_should_not_increment_profits(vault, strategy, token, token_whale, gov, amount):
    initialProfit = vault.strategies(strategy).dict()["totalGain"]
    assert initialProfit == 0

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert vault.strategies(strategy).dict()["totalGain"] == initialProfit


def test_direct_transfer_with_actual_profits(
    vault, strategy, token, amount, token_whale, baseToken, borrow_whale, depositer, gov, 
):
    initialProfit = vault.strategies(strategy).dict()["totalGain"]
    assert initialProfit == 0

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    # send some profit to depositer
    baseToken.transfer(
        depositer, amount / 2, {"from": borrow_whale}
    )

    # sleep for a day
    chain.sleep(24 * 3600)
    chain.mine(1)

    # receive a direct transfer
    airdropAmount = 1 * (10 ** token.decimals())
    token.transfer(strategy, airdropAmount, {"from": token_whale})

    # sleep for another day
    chain.sleep(24 * 3600)
    chain.mine(1)
    strategy.setDoHealthCheck(False, {"from": gov})
    strategy.harvest({"from": gov})
    assert (
        vault.strategies(strategy).dict()["totalGain"] > initialProfit + airdropAmount
    )
