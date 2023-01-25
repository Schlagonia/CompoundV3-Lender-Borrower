import pytest
from brownie import config, chain, Wei
from brownie import Contract


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass

@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def amount(accounts, token, token_whale):
    amount = 5 * (10 ** token.decimals())
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0xba12222222228d8ba445958a75a0704d566bf2c8", force=True)
    token.transfer(token_whale, amount, {"from": reserve})
    yield amount

@pytest.fixture
def bal_vault(accounts):
    yield accounts.at("0xba12222222228d8ba445958a75a0704d566bf2c8", force=True)


@pytest.fixture
def weth():
    yield Contract("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")

@pytest.fixture
def wbtc():
    yield Contract("0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599")

@pytest.fixture
def stEth():
    yield Contract("0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0")

@pytest.fixture
def comet(interface, token, stEth):
    if token == stEth:
        yield interface.Comet("0xA17581A9E3356d9A858b789D68B4d866e593aE94")
    else:
        yield interface.Comet("0xc3d688B66703497DAA19211EEdff47f25384cdc3")
        

@pytest.fixture
def baseToken(comet):
    yield Contract(comet.baseToken())

@pytest.fixture
def wbtc_whale(accounts):
    yield accounts.at("0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf", force=True)


@pytest.fixture
def weth_whale(accounts):
    yield accounts.at("0x2F0b23f53734252Bda2277357e97e1517d6B042A", force=True)

@pytest.fixture
def ethToWantFee():
    yield 3000 # wbtc/eth .3% pool

@pytest.fixture
def addresses():
    yield {
    "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",  # WBTC
    "YFI": "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e",  # YFI
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",  # LINK
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",  # USDT
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",  # DAI
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",  # USDC
    "STETH": "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
    }


@pytest.fixture(
    params=[
        # 'WBTC', # WBTC
        # "YFI",  # YFI
        # "WETH",  # WETH
        # 'LINK', # LINK
        # 'USDT', # USDT
        "DAI"
    ]
)
def token(addresses):
    yield Contract(addresses["STETH"])


@pytest.fixture(
    params=[
        # "yvWBTC", # yvWBTC
        # "yvWETH", # yvWETH
        # "yvUSDT",  # yvUSDT
        # "yvUSDC", # yvUSDC
        # "yvDAI" # yvDAI
        "yvSUSD"
    ],
)
def yvault():
    vault = Contract("0xa354F35829Ae975e850e23e9615b11Da1B3dC4DE")
    yield vault


@pytest.fixture
def borrow_token(yvault):
    yield Contract(yvault.token())


whales = {
    "WBTC": "0x28c6c06298d514db089934071355e5743bf21d60",  # binance14
    "WETH": "0x28c6c06298d514db089934071355e5743bf21d60",
    "LINK": "0x28c6c06298d514db089934071355e5743bf21d60",
    "YFI": "0x28c6c06298d514db089934071355e5743bf21d60",
    "USDT": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",  #
    "USDC": "0xba12222222228d8ba445958a75a0704d566bf2c8",
    "DAI": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",  #
    "sUSD": "0xA5407eAE9Ba41422680e2e00537571bcC53efBfD",
}


@pytest.fixture
def borrow_whale(borrow_token):
    yield whales[borrow_token.symbol()]


@pytest.fixture
def token_whale(token):
    yield whales[token.symbol()]


@pytest.fixture
def token_symbol(token):
    yield token.symbol()


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout

@pytest.fixture
def rewardsContract():
    yield Contract("0x1B0e765F6224C21223AeA2af16c1C46E38885a40")
    
@pytest.fixture
def registry():
    yield Contract("0x50c1a2eA0a861A967D9d0FFE2AE4012c2E053804")


@pytest.fixture
def live_vault(registry, token, stEth, vault):
    if token == stEth:
        yield vault
    else:
        yield Contract(registry.latestVault(token))


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management, {"from": gov})

    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    vault.setPerformanceFee(0, {"from": gov})
    yield vault

@pytest.fixture
def weth_vault(pm, gov, rewards, guardian, management, weth):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(weth, gov, rewards, "", "", guardian, management, {"from": gov})

    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    vault.setPerformanceFee(0, {"from": gov})
    yield vault

@pytest.fixture
def strategy(vault, Strategy, gov, cloner):
    strategy = Strategy.at(cloner.originalStrategy())
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})
    chain.mine()
    yield strategy

@pytest.fixture
def depositer(cloner, Depositer):
    yield Depositer.at(cloner.originalDepositer())

@pytest.fixture
def RELATIVE_APPROX():
    yield 1e-5


@pytest.fixture
def cloner(
    strategist,
    vault,
    CompV3LenderBorrowerCloner,
    comet,
    ethToWantFee,
    token,
    baseToken,
):
    cloner = strategist.deploy(
        CompV3LenderBorrowerCloner,
        vault,
        comet,
        ethToWantFee,
        f"Strategy{token.symbol()}Lender{baseToken.symbol()}Borrower",
    )

    yield cloner
