from brownie import chain, reverts, Contract
import pytest


def test_operation(token, vault, token_whale, strategy, strategist, amount, RELATIVE_APPROX):
    user_balance_before = token.balanceOf(token_whale)

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    #amount = 500_000 * (10 ** token.decimals())
    # Deposit to the vault
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(60 * 60)
    # withdrawal
    vault.withdraw({"from": token_whale})
    assert (
        pytest.approx(token.balanceOf(token_whale), rel=RELATIVE_APPROX)
        == user_balance_before
    )


def test_emergency_exit(
    token, vault, strategy, token_whale, strategist, RELATIVE_APPROX, amount
):
    # Deposit to the vault
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # set emergency and exit
    strategy.setEmergencyExit({"from": strategist})
    strategy.harvest({"from": strategist})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
    token,
    vault,
    strategy,
    token_whale,
    strategist,
    RELATIVE_APPROX,
    chain,
    borrow_token,
    borrow_whale,
    depositer,
    amount
):
    # Deposit to the vault
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
   
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # increase rewards, lending interest and borrowing interests
    chain.sleep(50 * 24 * 3600)
    chain.mine(1)

    strategy.harvest({"from": strategist})  # to claim and start cooldown

    chain.sleep(10 * 24 * 3600 + 1)  # sleep during cooldown
    chain.mine(1)

    before_pps = vault.pricePerShare()
    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    assert vault.totalAssets() > amount
    assert vault.pricePerShare() > before_pps


def test_change_debt(
    gov, token, vault, token_whale, strategy, user, strategist, RELATIVE_APPROX, amount
):
    # Deposit to the vault and harvest
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    half = int(amount / 2)

    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half
    chain.sleep(1)
    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # In order to pass this tests, you will need to implement prepareReturn.
    # TODO: uncomment the following lines.
    chain.sleep(1)
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    strategy.harvest({"from":gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half


def test_sweep(gov, vault, strategy, token, token_whale, borrow_whale, borrow_token, amount):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": token_whale})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    before_balance = borrow_token.balanceOf(gov)
    borrow_token.transfer(
        strategy, 1 * (10 ** borrow_token.decimals()), {"from": borrow_whale}
    )
    assert borrow_token.address != strategy.want()
    strategy.sweep(borrow_token, {"from": gov})
    assert (
        borrow_token.balanceOf(gov)
        == 1 * (10 ** borrow_token.decimals()) + before_balance
    )

def test_manuual_functions(gov, vault, strategy, token, token_whale, strategist, comet, depositer, borrow_token, amount, RELATIVE_APPROX):
    user_balance_before = token.balanceOf(token_whale)
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    
    # Deposit to the vault
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(10)

    comet.accrueAccount(depositer.address, {"from": strategist})
    assert borrow_token.balanceOf(strategy.address) == 0
    begining_debt = strategy.balanceOfDebt()

    #call from non-auth
    with reverts():
        strategy.manualWithdrawAndRepayDebt(depositer.cometBalance(), {"from": token_whale})

    #call with more than we can withdraw
    with reverts():
        strategy.manualWithdrawAndRepayDebt(depositer.cometBalance() + 100, {"from": strategist})

    #withdraw and repay all
    toWithdraw = depositer.accruedCometBalance({"from":strategist})
    strategy.manualWithdrawAndRepayDebt(toWithdraw.return_value, {"from": strategist})
    assert borrow_token.balanceOf(strategy.address) == 0
    assert  depositer.cometBalance() == 0
    assert strategy.balanceOfDebt() < begining_debt

    vault.withdraw({"from": token_whale})
    assert (
        pytest.approx(token.balanceOf(token_whale), rel=RELATIVE_APPROX)
        == user_balance_before
    )


def test_loss_and_airdrop(
    token,
    vault,
    strategy,
    token_whale,
    strategist,
    RELATIVE_APPROX,
    chain,
    borrow_token,
    borrow_whale,
    depositer,
    amount,
    gov
):
    user_balance_before = token.balanceOf(token_whale)
    # Deposit to the vault
    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
   
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    #simulate a loss
    yshares = depositer.cometBalance()
    depositer.withdraw(yshares /10, {"from": strategy.address})
    balance = borrow_token.balanceOf(strategy.address)
    borrow_token.transfer(gov, balance, {"from": strategy.address})

    assert vault.strategies(strategy.address)["totalDebt"] > strategy.estimatedTotalAssets()

    chain.sleep(1)

    #airdrop back the amount of token = loss
    borrow_token.transfer(strategy.address, balance, {"from": gov})

    chain.sleep(1)
    #make sure the health check is on so we cant report the loss
    assert strategy.doHealthCheck() == True
    strategy.harvest({"from": strategist})

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    vault.withdraw({"from": token_whale})
    assert (
        pytest.approx(token.balanceOf(token_whale), rel=RELATIVE_APPROX)
        == user_balance_before
    )
