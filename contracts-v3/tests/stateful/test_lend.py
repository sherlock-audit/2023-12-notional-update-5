import brownie
import pytest
from brownie.network.state import Chain
from brownie.test import given, strategy
from scripts.EventProcessor import processTxn
from tests.constants import HAS_CASH_DEBT, RATE_PRECISION
from tests.helpers import (
    active_currencies_to_list,
    get_balance_trade_action,
    initialize_environment,
)
from tests.snapshot import EventChecker
from tests.stateful.invariants import check_system_invariants

chain = Chain()


@pytest.fixture(scope="module", autouse=True)
def environment(accounts):
    return initialize_environment(accounts)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_lend_failures(environment, accounts):
    with brownie.reverts("No Prime Borrow"):
        action = get_balance_trade_action(
            2,
            "None",  # No balance
            [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Invalid market"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 3,  # invalid market
                    "notional": 100e8,
                    "minSlippage": 0,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("No Prime Borrow"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 500e8,  # insufficient cash
                    "minSlippage": 0,
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed, slippage"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [
                {
                    "tradeActionType": "Lend",
                    "marketIndex": 1,
                    "notional": 500e8,
                    "minSlippage": 0.40 * RATE_PRECISION,  # min bound
                }
            ],
            depositActionAmount=100e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Trade failed, liquidity"):
        action = get_balance_trade_action(
            2,
            "DepositAsset",
            [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 500000e8, "minSlippage": 0}],
            depositActionAmount=200000e8,
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

def test_deposit_underlying_and_lend_specify_fcash(environment, accounts):
    fCashAmount = environment.notional.getfCashAmountGivenCashAmount(2, -100e8, 1, chain.time() + 60)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": fCashAmount, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [fCashAmount],
        netCash=lambda x: 0 < x[2] and x[2] <= 10_000
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False)]
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == fCashAmount

    marketsAfter = environment.notional.getActiveMarkets(2)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)


@given(redeemToETH=strategy("bool"))
def test_deposit_eth_and_lend_specify_fcash(environment, accounts, redeemToETH):
    action = get_balance_trade_action(
        1,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=redeemToETH,
    )
    marketsBefore = environment.notional.getActiveMarkets(1)

    if redeemToETH:
        balanceBefore = accounts[1].balance()
    else:
        balanceBefore = environment.WETH.balanceOf(accounts[1])

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8],
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1], "value": 100e18}
        )
        c['txn'] = txn

    eventStore = processTxn(environment, txn)
    netPrimeCash = eventStore['transfers'][1]['value'] + eventStore['transfers'][2]['value']
    # Residual from prime cash is returned in either ETH or WETH based on redeemToETH
    if redeemToETH:
        balanceAfter = accounts[1].balance()
        assert environment.approxExternal(
            "ETH", -netPrimeCash, balanceAfter - balanceBefore
        )
    else:
        balanceAfter = environment.WETH.balanceOf(accounts[1])
        ethUsed = environment.notional.convertCashBalanceToExternal(
            1, netPrimeCash, True
        )
        # Remainder is refunded as WETH
        assert pytest.approx(100e18 - ethUsed, abs=1e10) == balanceAfter - balanceBefore

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(1, True, False)]
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 1
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    marketsAfter = environment.notional.getActiveMarkets(1)

    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_deposit_asset_and_lend(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8],
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == [(2, True, False)]
    assert context[1] == "0x00"
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    marketsAfter = environment.notional.getActiveMarkets(2)
    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)


def test_roll_lend_to_maturity(environment, accounts):
    action = get_balance_trade_action(
        2,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
    marketsBefore = environment.notional.getActiveMarkets(2)

    blockTime = chain.time() + 1
    (_, cash) = environment.notional.getCashAmountGivenfCashAmount(2, -100e8, 1, blockTime)
    fCashAmount = environment.notional.getfCashAmountGivenCashAmount(2, -cash, 2, blockTime)

    action = get_balance_trade_action(
        2,
        "None",
        [
            {"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0},
            {
                "tradeActionType": "Lend",
                "marketIndex": 2,
                "notional": fCashAmount,
                "minSlippage": 0,
            },
        ],
    )

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [-100e8, fCashAmount],
        netCash=lambda x: x[2] < 1e8
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    assert context[1] == "0x00"
    (residual, nToken, mint) = environment.notional.getAccountBalance(2, accounts[1])
    assert nToken == 0
    assert mint == 0
    assert residual < 1e8

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[1][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == fCashAmount

    check_system_invariants(environment, accounts)


def test_deposit_and_lend_bitmap(environment, accounts):
    currencyId = 2
    environment.notional.enableBitmapCurrency(currencyId, {"from": accounts[1]})

    action = get_balance_trade_action(
        currencyId,
        "DepositAsset",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5100e8,
        withdrawEntireCashBalance=True,
    )
    marketsBefore = environment.notional.getActiveMarkets(2)

    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8],
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    activeCurrenciesList = active_currencies_to_list(context[4])
    assert activeCurrenciesList == []
    assert context[1] == "0x00"
    assert context[2] == 0
    assert context[3] == 2
    assert (0, 0, 0) == environment.notional.getAccountBalance(2, accounts[1])

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert portfolio[0][0] == 2
    assert portfolio[0][1] == marketsBefore[0][1]
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    marketsAfter = environment.notional.getActiveMarkets(2)
    assert marketsBefore[1] == marketsAfter[1]
    assert marketsBefore[0][2] - marketsAfter[0][2] == portfolio[0][3]
    assert marketsBefore[0][4] - marketsAfter[0][4] == 0
    assert marketsBefore[0][5] > marketsAfter[0][5]

    check_system_invariants(environment, accounts)

@given(useBitmap=strategy("bool"))
def test_borrow_prime_to_lend_fixed(environment, accounts, useBitmap):
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=5e18,
        withdrawEntireCashBalance=True,
        redeemToUnderlying=True,
    )

    marketsBefore = environment.notional.getActiveMarkets(2)
    (depositAmountUnderlying, _, _, _) = environment.notional.getDepositFromfCashLend(
        2, 100e8, marketsBefore[0][1], 0, chain.time()
    )

    with brownie.reverts("No Prime Borrow"):
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    with EventChecker(environment, "Account Action",
        account=accounts[1],
        netfCashAssets=lambda x: list(x.values()) == [100e8],
        netCash=lambda x: x[2] < 10
    ) as c:
        txn = environment.notional.batchBalanceAndTradeAction(accounts[1], [action], {"from": accounts[1]})
        c['txn'] = txn

    context = environment.notional.getAccountContext(accounts[1])
    if useBitmap:
        assert context["bitmapCurrencyId"] == 2
    else:
        activeCurrenciesList = active_currencies_to_list(context[4])
        assert activeCurrenciesList == [(2, True, True)]

    assert context["hasDebt"] == HAS_CASH_DEBT
    (cashBalance, _, _) = environment.notional.getAccountBalance(2, accounts[1])

    # Allow more leeway here because of debt accrual
    assert (
        pytest.approx(
            environment.notional.convertCashBalanceToExternal(2, cashBalance, True), abs=500e10
        )
        == -depositAmountUnderlying + 5e18
    )

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    # Assert that the account is accruing variable debt
    chain.mine(1, timedelta=86400 * 7)
    (cashBalance2, _, _) = environment.notional.getAccountBalance(2, accounts[1])
    assert cashBalance2 < cashBalance

    check_system_invariants(environment, accounts)

@given(useBitmap=strategy("bool"))
def test_lend_fails_on_supply_cap(environment, accounts, useBitmap):
    currencyId = 2
    if useBitmap:
        environment.notional.enableBitmapCurrency(2, {"from": accounts[1]})

    factors = environment.notional.getPrimeFactorsStored(currencyId)
    environment.notional.setMaxUnderlyingSupply(currencyId, factors['lastTotalUnderlyingValue'] + 1e8, 70)

    action = get_balance_trade_action(
        2,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=100e18,
        withdrawEntireCashBalance=True,
    )

    with brownie.reverts("Over Supply Cap"):
        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    # Increase supply cap
    environment.notional.setMaxUnderlyingSupply(currencyId, factors['lastTotalUnderlyingValue'] + 100e8, 100)

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    portfolio = environment.notional.getAccountPortfolio(accounts[1])
    assert len(portfolio) == 1
    assert portfolio[0][0] == 2
    assert portfolio[0][2] == 1
    assert portfolio[0][3] == 100e8

    check_system_invariants(environment, accounts)

def test_can_lend_when_debt_cap_exceeded(environment, accounts):
    factors = environment.notional.getPrimeFactors(3, chain.time() + 1)
    # Have to buffer the max supply a bit to ensure that interest accrual does not
    # push this over the cap immediately
    maxSupply = factors['factors']['lastTotalUnderlyingValue'] * 1.10
    environment.notional.setMaxUnderlyingSupply(3, maxSupply, 70)
    factors = environment.notional.getPrimeFactors(3, chain.time() + 1)

    environment.notional.enablePrimeBorrow(True, {"from": accounts[0]})

    # Can borrow up to debt cap
    maxPrimeCash = environment.notional.convertUnderlyingToPrimeCash(3, factors['maxUnderlyingDebt'] / 100)
    environment.notional.withdraw(3, maxPrimeCash, True, {"from": accounts[0]})

    with brownie.reverts("Over Debt Cap"):
        environment.notional.withdraw(3, 1e8, True, {"from": accounts[0]})

    action = get_balance_trade_action(
        3,
        "DepositUnderlying",
        [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        depositActionAmount=100e6,
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [action], {"from": accounts[1]}
    )

    borrow = get_balance_trade_action(
        3,
        "DepositUnderlying",
        [{"tradeActionType": "Borrow", "marketIndex": 1, "notional": 100e8, "maxSlippage": 0}],
        withdrawEntireCashBalance=True,
    )

    environment.notional.batchBalanceAndTradeAction(
        accounts[1], [borrow], {"from": accounts[1]}
    )

    check_system_invariants(environment, accounts)

def test_cannot_leveraged_lend_over_debt_cap(environment, accounts):
    factors = environment.notional.getPrimeFactors(3, chain.time() + 1)
    # Have to buffer the max supply a bit to ensure that interest accrual does not
    # push this over the cap immediately
    maxSupply = factors['factors']['lastTotalUnderlyingValue'] * 1.10
    environment.notional.setMaxUnderlyingSupply(3, maxSupply, 70)
    factors = environment.notional.getPrimeFactors(3, chain.time() + 1)

    environment.notional.enablePrimeBorrow(True, {"from": accounts[0]})

    # Can borrow up to debt cap
    maxPrimeCash = environment.notional.convertUnderlyingToPrimeCash(3, factors['maxUnderlyingDebt'] / 100)
    environment.notional.withdraw(3, maxPrimeCash, True, {"from": accounts[0]})

    with brownie.reverts("Over Debt Cap"):
        environment.notional.withdraw(3, 1e8, True, {"from": accounts[0]})

    environment.notional.enablePrimeBorrow(True, {"from": accounts[1]})
    environment.notional.depositUnderlyingToken(
        accounts[1], 1, 100e18, {"from": accounts[1], "value": 100e18}
    )

    with brownie.reverts("Over Debt Cap"):
        # This executes a leveraged lend by borrowing variable
        action = get_balance_trade_action(
            3,
            "None",
            [{"tradeActionType": "Lend", "marketIndex": 1, "notional": 100e8, "minSlippage": 0}],
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    with brownie.reverts("Over Debt Cap"):
        # This executes a leveraged liquidity by borrowing variable
        action = get_balance_trade_action(
            3,
            "ConvertCashToNToken",
            [],
            depositActionAmount=100e8
        )

        environment.notional.batchBalanceAndTradeAction(
            accounts[1], [action], {"from": accounts[1]}
        )

    check_system_invariants(environment, accounts)