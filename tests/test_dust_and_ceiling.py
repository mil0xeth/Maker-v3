import pytest

from brownie import chain, reverts, Wei


def test_small_deposit_does_not_generate_debt_under_floor(
    vault, test_strategy, token, token_whale, yvault, borrow_token, gov, maker_debt_floor, RELATIVE_APPROX
):
    price = test_strategy._getPrice()
    floor = maker_debt_floor*0.99  # assume a price floor of 5k as in ETH-C

    # Amount in want that generates 'floor' debt minus a treshold
    token_floor = ((test_strategy.collateralizationRatio() * floor / 1e18) / price) * (
        10 ** token.decimals()
    )

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, token_floor, {"from": token_whale})

    vault.deposit(token_floor, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # Debt floor is 5k for ETH-C, so the strategy should not take any debt
    # with a lower deposit amount
    assert test_strategy.balanceOfDebt() == 0
    assert yvault.balanceOf(test_strategy) == 0
    assert borrow_token.balanceOf(test_strategy) == 0

    # These are zero because all want is locked in Maker's vault
    assert pytest.approx(test_strategy.balanceOfMakerVault(), rel=RELATIVE_APPROX) == token_floor
    assert token.balanceOf(test_strategy) == 0
    assert token.balanceOf(vault) == 0

    # Collateral with no debt should be a high ratio
    assert (
        test_strategy._getCurrentMakerVaultRatio()
        > test_strategy.collateralizationRatio()
    )


def test_deposit_after_passing_debt_floor_generates_debt(
    vault, test_strategy, token, token_whale, yvault, borrow_token, gov, RELATIVE_APPROX, maker_debt_floor
):
    price = test_strategy._getPrice()
    floor = maker_debt_floor*0.99  # assume a price floor of 5k as in ETH-C

    # Amount in want that generates 'floor' debt minus a treshold
    token_floor = ((test_strategy.collateralizationRatio() * floor / 1e18) / price) * (
        10 ** token.decimals()
    )

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(token_floor, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # Debt floor is 10k for YFI-A, so the strategy should not take any debt
    # with a lower deposit amount
    assert test_strategy.balanceOfDebt() == 0
    assert yvault.balanceOf(test_strategy) == 0
    assert borrow_token.balanceOf(test_strategy) == 0
    assert pytest.approx(test_strategy.balanceOfMakerVault(), rel=RELATIVE_APPROX) == token_floor

    # Deposit enough want token to go over the dust
    additional_deposit = maker_debt_floor*0.05

    vault.deposit(additional_deposit, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # Ensure that we have now taken on debt and deposited into yVault
    assert yvault.balanceOf(test_strategy) > 0
    assert test_strategy.balanceOfDebt() > 0
    assert pytest.approx(test_strategy.balanceOfMakerVault(), rel=RELATIVE_APPROX) == token_floor + additional_deposit

    # Collateral with no debt should be a high ratio
    assert test_strategy._getCurrentMakerVaultRatio()*1.1 >= test_strategy.collateralizationRatio()


def test_withdraw_does_not_leave_debt_under_floor(
    vault, test_strategy, token, token_whale, yvault, dai, dai_whale, gov, amount
):
    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # We took some debt and deposited into yvDAI
    assert yvault.balanceOf(test_strategy) > 0

    # Send profits to yVault
    dai.transfer(yvault, yvault.totalAssets() * 0.03, {"from": dai_whale})

    shares = yvault.balanceOf(test_strategy)

    # Withdraw large amount so remaining debt is under floor
    vault.withdraw(amount*0.9999, {"from": token_whale})

    # Almost all yvDAI shares should have been used to repay the debt
    # and avoid the floor
    assert (yvault.balanceOf(test_strategy) - (shares - shares * (1 / 1.03))) < 1e18

    # Because collateral balance is much larger than the debt (currently 0)
    # we expect the current ratio to be above target
    assert (
        test_strategy._getCurrentMakerVaultRatio()
        > test_strategy.collateralizationRatio()
    )


def test_withdraw_everything_with_vault_in_debt_ceiling(
    vault, test_strategy, token, token_whale, yvault, gov, RELATIVE_APPROX
):
    amount = token.balanceOf(token_whale)

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    test_strategy.setLeaveDebtBehind(False, {"from": gov})
    vault.withdraw({"from": token_whale})

    assert vault.strategies(test_strategy).dict()["totalDebt"] == 0
    assert test_strategy._getCurrentMakerVaultRatio() == 0
    assert yvault.balanceOf(test_strategy) < 1e18  # dust
    assert pytest.approx(token.balanceOf(token_whale), rel=RELATIVE_APPROX) == amount



def test_withdraw_everything_cancels_entire_debt(
    vault, test_strategy, token, token_whale, user, amount, yvault, dai, dai_whale, gov
):
    amount_user = amount
    amount_whale = amount*10

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount_whale, {"from": token_whale})

    token.approve(vault.address, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount_user, {"from": user})

    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # Send profits to yVault
    dai.transfer(yvault, yvault.totalAssets() * 0.00001, {"from": dai_whale})

    assert vault.withdraw({"from": token_whale}).return_value == amount_whale
    assert vault.withdraw({"from": user}).return_value == amount_user
    assert vault.strategies(test_strategy).dict()["totalDebt"] == 0


def test_withdraw_under_floor_without_funds_to_cancel_entire_debt_should_fail(
    vault, test_strategy, token, token_whale, gov, yvault, maker_debt_floor
):
    # Make sure the strategy will not sell want to repay debt
    test_strategy.setLeaveDebtBehind(False, {"from": gov})

    price = test_strategy._getPrice()
    floor = maker_debt_floor*1.05  # assume a price floor of 5k as in ETH-C

    # Amount in want that generates 'floor' debt minus a treshold
    token_floor = ((test_strategy.collateralizationRatio() * floor / 1e18) / price) * (
        10 ** token.decimals()
    )

    lower_rebalancing_bound = (
        test_strategy.collateralizationRatio() - test_strategy.rebalanceTolerance()
    )
    min_floor_in_band = (
        token_floor * lower_rebalancing_bound / test_strategy.collateralizationRatio()
    )

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(token_floor, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    max_withdrawal = token_floor - min_floor_in_band - Wei("0.0001 ether")

    # Simulate a loss in yvault by sending some shares away
    yvault.transfer(
        token_whale, yvault.balanceOf(test_strategy) * 0.01, {"from": test_strategy}
    )

    assert (
        vault.withdraw(max_withdrawal, {"from": token_whale}).return_value
        == max_withdrawal
    )

    # We are not simulating any profit in yVault, so there will not
    # be enough to repay the debt
    with reverts():
        vault.withdraw({"from": token_whale})


def test_small_withdraw_cancels_corresponding_debt(
    vault, strategy, token, token_whale, yvault, gov, RELATIVE_APPROX, amount
):
    to_withdraw_pct = 0.2

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})

    # Shares in yVault at the current target ratio
    shares_before = yvault.balanceOf(strategy)

    assert (
        vault.withdraw(amount * to_withdraw_pct, {"from": token_whale}).return_value
        == amount * to_withdraw_pct
    )

    assert pytest.approx(
        shares_before * (1 - to_withdraw_pct), rel=RELATIVE_APPROX
    ) == yvault.balanceOf(strategy)


def test_tend_trigger_with_debt_under_dust_returns_false(
    vault, test_strategy, token, token_whale, gov, maker_debt_floor
):
    price = test_strategy._getPrice()
    floor = maker_debt_floor*0.95 # assume a price floor of 5k as in ETH-C

    # Amount in want that generates 'floor' debt minus a treshold
    token_floor = ((test_strategy.collateralizationRatio() * floor / 1e18) / price) * (
        10 ** token.decimals()
    )

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, token_floor, {"from": token_whale})

    vault.deposit(token_floor, {"from": token_whale})
    chain.sleep(1)
    test_strategy.harvest({"from": gov})

    # Debt floor is 5k for ETH-C, so the strategy should not take any debt
    # with a lower deposit amount
    assert test_strategy.tendTrigger(1) == False


def test_tend_trigger_without_more_mintable_dai_returns_false(
    vault, strategy, token, token_whale, gov, amount
):
    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    # Send the funds through the strategy to invest
    chain.sleep(1)
    strategy.harvest({"from": gov})

    assert strategy.tendTrigger(1) == False

    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(token.balanceOf(token_whale), {"from": token_whale})
    chain.sleep(1)
    strategy.harvest({"from": gov})

    assert strategy.tendTrigger(1) == False


def test_tend_trigger_with_funds_in_cdp_but_no_debt_returns_false(
    vault, strategy, token, token_whale, gov, dai, dai_whale, yvDAI, amount
):
    # Deposit to the vault and send funds through the strategy
    token.approve(vault.address, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    # Send the funds through the strategy to invest
    chain.sleep(1)
    strategy.harvest({"from": gov})

    assert strategy.tendTrigger(1) == False

    # Send some profit to yVault
    dai.transfer(yvDAI, yvDAI.totalAssets() * 0.005, {"from": dai_whale})

    # Harvest 2: Realize profit
    strategy.harvest({"from": gov})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    strategy.emergencyDebtRepayment(0, {"from": vault.management()})

    assert strategy.balanceOfMakerVault() > 0
    assert strategy.balanceOfDebt() == 0
    assert strategy.getCurrentMakerVaultRatio() / 1e18 > 1000
    assert strategy.tendTrigger(1) == False
