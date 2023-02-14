// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {IERC20,Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libraries/MakerDaiDelegateLib.sol";

import "../interfaces/yearn/IBaseFee.sol";
import "../interfaces/yearn/IOSMedianizer.sol";
import "../interfaces/yearn/IVault.sol";

import "../interfaces/chainlink/AggregatorInterface.sol";

import "../interfaces/IERC20Metadata.sol";

import "../interfaces/ySwaps/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    
    // Units used in Maker contracts
    uint256 internal constant WAD = 10**18;
    uint256 internal constant RAY = 10**27;

    // DAI token
    IERC20 internal constant investmentToken = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    // 100%
    uint256 internal constant MAX_BPS = WAD;

    // Maximum loss on withdrawal from yVault
    uint256 internal constant MAX_LOSS_BPS = 10000;

    // 0 = sushi, 1 = univ2, 2 = univ3, 3 & 3+ = yswaps
    uint24 public swapRouterSelection;
    // fee pools in case of a swapRouterSelection of 2 = univ3 to swap from DAI to midToken (intermediary swap token):
    uint24 public feeInvestmentTokenToMidUNIV3;
    // fee pools in case of a swapRouterSelection of 2 = univ3 to swap from midToken to want:
    uint24 public feeMidToWantUNIV3;
    // 0 = through WETH, 1 = through USDC, 2 = direct swap
    uint24 public midTokenChoice;

    //ySwaps:
    address public tradeFactory;

    // BaseFee Oracle:
    address internal constant baseFeeOracle = 0xb5e1CAcB567d98faaDB60a1fD4820720141f064F;

    uint256 public creditThreshold; // amount of credit in underlying tokens that will automatically trigger a harvest
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    // Token Adapter Module for collateral
    address internal gemJoinAdapter;

    // Maker Oracle Security Module
    IOSMedianizer public wantToUSDOSMProxy;

    // Use Chainlink oracle to obtain latest want/USD price
    AggregatorInterface public chainlinkWantToUSDPriceFeed;

    // DAI yVault
    IVault public yVault;

    // Collateral type
    bytes32 internal ilk;

    uint256 internal convertWantTo18Decimals;

    // Our vault identifier
    uint256 public cdpId;

    // Our desired collaterization ratio
    uint256 public collateralizationRatio;

    // Allow the collateralization ratio to drift a bit in order to avoid cycles
    uint256 public rebalanceTolerance;

    // Maximum acceptable swap slippage. Default to 5%.
    uint256 public swapSlippage;
    uint256 internal constant DENOMINATOR = 100_00;

    // Maximum acceptable loss on withdrawal. Default to 0.01%.
    uint256 public maxLoss;

    // If set to true the strategy will never try to repay debt by selling want
    bool public leaveDebtBehind;

    // Name of the strategy
    string internal strategyName;

    // ----------------- INIT FUNCTIONS TO SUPPORT CLONING -----------------

    constructor(
        address _vault,
        address _yVault,
        string memory _strategyName,
        bytes32 _ilk,
        address _gemJoin,
        address _wantToUSDOSMProxy,
        address _chainlinkWantToUSDPriceFeed
    ) public BaseStrategy(_vault) {
        _initializeThis(
            _yVault,
            _strategyName,
            _ilk,
            _gemJoin,
            _wantToUSDOSMProxy,
            _chainlinkWantToUSDPriceFeed
        );
    }

    function initialize(
        address _vault,
        address _yVault,
        string memory _strategyName,
        bytes32 _ilk,
        address _gemJoin,
        address _wantToUSDOSMProxy,
        address _chainlinkWantToUSDPriceFeed
    ) public {
        // Make sure we only initialize one time
        require(address(yVault) == address(0)); // dev: strategy already initialized

        address sender = msg.sender;

        // Initialize BaseStrategy
        _initialize(_vault, sender, sender, sender);

        // Initialize cloned instance
        _initializeThis(
            _yVault,
            _strategyName,
            _ilk,
            _gemJoin,
            _wantToUSDOSMProxy,
            _chainlinkWantToUSDPriceFeed
        );
    }

    function _initializeThis(
        address _yVault,
        string memory _strategyName,
        bytes32 _ilk,
        address _gemJoin,
        address _wantToUSDOSMProxy,
        address _chainlinkWantToUSDPriceFeed
    ) internal {
        uint256 wantDecimals = uint256(IERC20Metadata(address(want)).decimals());
        if (wantDecimals < 18){
            convertWantTo18Decimals = 10**18 / 10**wantDecimals;
        } else {
            convertWantTo18Decimals = 1;
        }
        require(_yVault != address(0)); //input validation
        yVault = IVault(_yVault);
        strategyName = _strategyName;
        ilk = _ilk;
        gemJoinAdapter = _gemJoin;
        wantToUSDOSMProxy = IOSMedianizer(_wantToUSDOSMProxy);
        chainlinkWantToUSDPriceFeed = AggregatorInterface(_chainlinkWantToUSDPriceFeed);
        minReportDelay = 30 days; // time to trigger harvesting by keeper depending on gas base fee
        maxReportDelay = 100 days; // time to trigger haresting by keeper no matter what
        creditThreshold = 1e6 * 1e18/convertWantTo18Decimals; //Credit threshold is in want token, and will trigger a harvest if strategy credit is above this amount.

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;

        cdpId = MakerDaiDelegateLib.openCdp(ilk);
        require(cdpId > 0); // dev: error opening cdp

        // Current ratio can drift (collateralizationRatio - rebalanceTolerance, collateralizationRatio + rebalanceTolerance)
        // Allow additional 15% in any direction (210, 240) by default
        rebalanceTolerance = (15 * MAX_BPS) / 100;

        // Minimum collaterization ratio on YFI-A is 175%
        // Use 225% as target
        collateralizationRatio = (225 * MAX_BPS) / 100;

        // If we lose money in yvDAI then we are not OK selling want to repay it
        leaveDebtBehind = true;

        // Define maximum acceptable slippage for swaps to be 5%.
        swapSlippage = 500;

        // Define maximum acceptable loss on withdrawal to be 0.01%.
        maxLoss = 1;

    }

    // ----------------- SETTERS & MIGRATION -----------------
    
    ///@notice Change OSM Proxy.
    function setWantToUSDOSMProxy(address _wantToUSDOSMProxy) external onlyGovernance {
        wantToUSDOSMProxy = IOSMedianizer(_wantToUSDOSMProxy);
    }
    
    ///@notice Change Chainlink Oracle.
    function setChainlinkOracle(address _chainlinkWantToUSDPriceFeed) external onlyGovernance {
        chainlinkWantToUSDPriceFeed = AggregatorInterface(_chainlinkWantToUSDPriceFeed);
    }

    ///@notice Force manual harvest through keepers using KP3R instead of ETH:
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyEmergencyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice Set Amount of credit in underlying want tokens that will automatically trigger a harvest
    function setCreditThreshold(uint256 _creditThreshold) external onlyEmergencyAuthorized
    {
        creditThreshold = _creditThreshold;
    }

    ///@notice Target collateralization ratio to maintain within bounds by keeper automation
    function setCollateralizationRatio(uint256 _collateralizationRatio) external onlyVaultManagers
    {
        require(_collateralizationRatio.sub(rebalanceTolerance) > MakerDaiDelegateLib.getLiquidationRatio(ilk).mul(MAX_BPS).div(RAY)); // check if desired collateralization ratio is too low
        collateralizationRatio = _collateralizationRatio;
    }

    ///@notice Set Rebalancing bands (collat ratio - tolerance, collat_ratio + tolerance)
    function setRebalanceTolerance(uint256 _rebalanceTolerance)
        external
        onlyVaultManagers
    {
        require(collateralizationRatio.sub(_rebalanceTolerance) > MakerDaiDelegateLib.getLiquidationRatio(ilk).mul(MAX_BPS).div(RAY)); // check if desired rebalance tolerance makes allowed ratio too low
        rebalanceTolerance = _rebalanceTolerance;
    }

    // Max slippage to accept when withdrawing from yVault & max swap slippage to accept from swapping
    function setMaxLossSwapSlippage(uint256 _maxLoss, uint256 _swapSlippage) external onlyVaultManagers {
        require(_maxLoss <= MAX_LOSS_BPS && _swapSlippage <= MAX_LOSS_BPS); // dev: invalid value for max loss
        maxLoss = _maxLoss;
        swapSlippage = _swapSlippage;
    }

    // If set to true the strategy will never sell want to repay debts
    function setLeaveDebtBehind(bool _leaveDebtBehind)
        external
        onlyVaultManagers
    {
        leaveDebtBehind = _leaveDebtBehind;
    }

    // Required to move funds to a new cdp and use a different cdpId after migration - Should only be called by governance as it will move funds
    function shiftToCdp(uint256 newCdpId) external onlyGovernance {
        MakerDaiDelegateLib.shiftCdp(cdpId, newCdpId);
        cdpId = newCdpId;
    }

    // Move yvDAI funds to a new yVault - Should only be called by governance as it will move funds
    function migrateToNewDaiYVault(IVault newYVault) external onlyGovernance {
        uint256 balanceOfYVault = yVault.balanceOf(address(this));
        if (balanceOfYVault > 0) {
            yVault.withdraw(balanceOfYVault, address(this), maxLoss);
        }
        investmentToken.safeApprove(address(yVault), 0);

        yVault = newYVault;
        _depositInvestmentTokenInYVault();
    }

    // Allow address to manage Maker's CDP - Should only be called by governance as it would allow to move funds
    function grantCdpManagingRightsToUser(address user, bool allow)
        external
        onlyGovernance
    {
        MakerDaiDelegateLib.allowManagingCdp(cdpId, user, allow);
    }

    ///@notice Allow switching the swapRouter between Sushi (0), Univ2 (1), Univ3 (2), yswaps (3 and 3+). If Univ3 (2) is chosen, the pool fees have to be chosen (100, 500 or 3000) from DAI to midToken and from midToken to Want. MidToken is the intermediatry token to swap to with 0 = WETH, 1 = USDC, 2 = direct swap
    function setSwapRouterSelection(uint24 _swapRouterSelection, uint24 _feeInvestmentTokenToMidUNIV3, uint24 _feeMidToWantUNIV3, uint24 _midTokenChoice) external onlyVaultManagers {
        swapRouterSelection = _swapRouterSelection;
        feeInvestmentTokenToMidUNIV3 = _feeInvestmentTokenToMidUNIV3;
        feeMidToWantUNIV3 = _feeMidToWantUNIV3;
        midTokenChoice = _midTokenChoice;
    }

    // Allow external debt repayment
    // Attempt to take currentRatio to target c-ratio
    // Passing zero will repay all debt if possible
    function emergencyDebtRepayment(uint256 currentRatio)
        external
        onlyVaultManagers
    {
        _repayDebt(currentRatio);
    }

    // Allow repayment of an arbitrary amount of Dai without having to
    // grant access to the CDP in case of an emergency
    // Difference with `emergencyDebtRepayment` function above is that here we
    // are short-circuiting all strategy logic and repaying Dai at once
    // This could be helpful if for example yvDAI withdrawals are failing and
    // we want to do a Dai airdrop and direct debt repayment instead
    function repayDebtWithDaiBalance(uint256 amount)
        external
        onlyVaultManagers
    {
        _repayInvestmentTokenDebt(amount);
    }

    // ******** OVERRIDEN METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return strategyName;
    }

    function delegatedAssets() external view override returns (uint256) {
        return _convertInvestmentTokenToWant(_valueOfInvestment());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return
            balanceOfWant()
                .add(balanceOfMakerVault().div(convertWantTo18Decimals))
                .add(_convertInvestmentTokenToWant(balanceOfInvestmentToken()))
                .add(_convertInvestmentTokenToWant(_valueOfInvestment()))
                .sub(_convertInvestmentTokenToWant(balanceOfDebt()));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Claim rewards from yVault
        _takeYVaultProfit();

        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

        _profit = totalAssetsAfterProfit > totalDebt ? totalAssetsAfterProfit.sub(totalDebt) : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(_debtOutstanding.add(_profit));
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Update accumulated stability fees,  Update the debt ceiling using DSS Auto Line
        MakerDaiDelegateLib.keepBasicMakerHygiene(ilk);
        // If we have enough want to deposit more into the maker vault, we do it
        // Do not skip the rest of the function as it may need to repay or take on more debt
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            uint256 amountToDeposit = wantBalance.sub(_debtOutstanding);
            _depositToMakerVault(amountToDeposit);
        }
        // Allow the ratio to move a bit in either direction to avoid cycles
        uint256 currentRatio = getCurrentMakerVaultRatio();
        if (currentRatio < collateralizationRatio.sub(rebalanceTolerance)) {
            _repayDebt(currentRatio);
        } else if (
            currentRatio > collateralizationRatio.add(rebalanceTolerance)
        ) {
            _mintMoreInvestmentToken();
        }
        
        // If we have anything left to invest then deposit into the yVault
        _depositInvestmentTokenInYVault();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();

        // Check if we can handle it without freeing collateral
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // We only need to free the amount of want not readily available. Convert from want decimals to collateral decimals (== always 18 decimals)
        uint256 amountToFree = _amountNeeded.sub(balance).mul(convertWantTo18Decimals);

        uint256 price = _getCollateralPrice();
        uint256 collateralBalance = balanceOfMakerVault();

        // We cannot free more than what we have locked
        amountToFree = Math.min(amountToFree, collateralBalance);

        uint256 totalDebt = balanceOfDebt();

        // If for some reason we do not have debt, make sure the operation does not revert
        if (totalDebt == 0) {
            totalDebt = 1;
        }

        uint256 toFreeIT = amountToFree.mul(price).div(WAD);
        uint256 collateralIT = collateralBalance.mul(price).div(WAD);
        uint256 newRatio = collateralIT.sub(toFreeIT).mul(MAX_BPS).div(totalDebt);

        // Attempt to repay necessary debt to restore the target collateralization ratio
        _repayDebt(newRatio);

        // Unlock as much collateral as possible while keeping the target ratio
        amountToFree = Math.min(amountToFree, _maxWithdrawal());
        _freeCollateralAndRepayDai(amountToFree, 0);

        // If we still need more want to repay, we may need to unlock some collateral to sell
        if (
            !leaveDebtBehind &&
            balanceOfWant() < _amountNeeded &&
            balanceOfDebt() > 0
        ) {
            _sellCollateralToRepayRemainingDebtIfNeeded();
        }

        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    function harvestTrigger(uint256)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        if (block.timestamp.sub(params.lastReport) > minReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function tendTrigger(uint256)
        public
        view
        override
        returns (bool)
    {
        // Nothing to adjust if there is no collateral locked
        if (balanceOfMakerVault() == 0) {
            return false;
        }

        uint256 currentRatio = getCurrentMakerVaultRatio();

        // If we need to repay debt and are outside the tolerance bands,
        // we do it regardless of the call cost
        if (currentRatio < collateralizationRatio.sub(rebalanceTolerance)) {
            return true;
        }

        // Mint more DAI if possible
        return
            currentRatio > collateralizationRatio.add(rebalanceTolerance) &&
            balanceOfDebt() > 0 &&
            isBaseFeeAcceptable() &&
            MakerDaiDelegateLib.isDaiAvailableToMint(ilk);
    }

    function prepareMigration(address _newStrategy) internal override {
        // Transfer Maker Vault ownership to the new startegy
        MakerDaiDelegateLib.transferCdp(cdpId, _newStrategy);

        // Move yvDAI balance to the new strategy
        IERC20(yVault).safeTransfer(
            _newStrategy,
            yVault.balanceOf(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {}

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _repayDebt(uint256 currentRatio) internal {
        uint256 currentDebt = balanceOfDebt();

        // Nothing to repay if we are over the collateralization ratio
        // or there is no debt
        if (currentRatio > collateralizationRatio || currentDebt == 0) {
            return;
        }

        // ratio = collateral / debt
        // collateral = current_ratio * current_debt
        // collateral amount is invariant here so we want to find new_debt
        // so that new_debt * desired_ratio = current_debt * current_ratio
        // new_debt = current_debt * current_ratio / desired_ratio
        // and the amount to repay is the difference between current_debt and new_debt
        uint256 newDebt = currentDebt.mul(currentRatio).div(collateralizationRatio);
        uint256 amountToRepay;

        // Maker will revert if the outstanding debt is less than a debt floor
        // called 'dust'. If we are there we need to either pay the debt in full
        // or leave at least 'dust' balance (10,000 DAI for YFI-A)
        uint256 debtFloor = MakerDaiDelegateLib.debtFloor(ilk);
        if (newDebt <= debtFloor) {
            // If we sold want to repay debt we will have DAI readily available in the strategy
            // This means we need to count both yvDAI shares and current DAI balance
            uint256 totalInvestmentAvailableToRepay = _valueOfInvestment().add(balanceOfInvestmentToken());
            if (totalInvestmentAvailableToRepay >= currentDebt) {
                // Pay the entire debt if we have enough investment token
                amountToRepay = currentDebt;
            } else {
                // Pay just 0.1 cent above debtFloor (best effort without liquidating want)
                amountToRepay = currentDebt.sub(debtFloor).sub(1e15);
            }
        } else {
            // If we are not near the debt floor then just pay the exact amount
            // needed to obtain a healthy collateralization ratio
            amountToRepay = currentDebt.sub(newDebt);
        }
        uint256 balanceIT = balanceOfInvestmentToken();
        if (amountToRepay > balanceIT) {
            _withdrawFromYVault(amountToRepay.sub(balanceIT));
        }
        _repayInvestmentTokenDebt(amountToRepay);
    }

    function _sellCollateralToRepayRemainingDebtIfNeeded() internal {
        uint256 investmentLeftToAcquire = balanceOfDebt().sub(_valueOfInvestment());
        uint256 investmentLeftToAcquireInWant = _convertInvestmentTokenToWant(investmentLeftToAcquire);

        if (investmentLeftToAcquireInWant <= balanceOfWant()) {
            //buy investmentToken with want (investmentLeftToAcquire)
            _swapKnownOutWantToInvestmentToken(investmentLeftToAcquire);
            _repayDebt(0);
            _freeCollateralAndRepayDai(balanceOfMakerVault(), 0);
        }
    }

    // Mint the maximum DAI possible for the locked collateral
    function _mintMoreInvestmentToken() internal {
        uint256 daiToMint = balanceOfMakerVault().mul(_getCollateralPrice()).mul(MAX_BPS).div(collateralizationRatio).div(WAD);
        daiToMint = daiToMint.sub(balanceOfDebt());
        _lockCollateralAndMintDai(0, daiToMint);
    }

    function _withdrawFromYVault(uint256 _amountIT) internal returns (uint256) {
        if (_amountIT == 0) {
            return 0;
        }
        // No need to check allowance because the contract == token
        uint256 balancePrior = balanceOfInvestmentToken();
        uint256 sharesToWithdraw = Math.min(_investmentTokenToYShares(_amountIT), yVault.balanceOf(address(this)));
        if (sharesToWithdraw == 0) {
            return 0;
        }
        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
        return balanceOfInvestmentToken().sub(balancePrior);
    }

    function _depositInvestmentTokenInYVault() internal {
        uint256 balanceIT = balanceOfInvestmentToken();
        if (balanceIT > 0) {_checkAllowance(address(yVault), address(investmentToken), balanceIT);
            yVault.deposit();
        }
    }

    function _repayInvestmentTokenDebt(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        uint256 debt = balanceOfDebt();
        uint256 balanceIT = balanceOfInvestmentToken();

        // We cannot pay more than loose balance
        amount = Math.min(amount, balanceIT);

        // We cannot pay more than we owe
        amount = Math.min(amount, debt);

        _checkAllowance(MakerDaiDelegateLib.daiJoinAddress(), address(investmentToken), amount);

        if (amount > 0) {
            // When repaying the full debt it is very common to experience Vat/dust
            // reverts due to the debt being non-zero and less than the debt floor.
            // This can happen due to rounding when _wipeAndFreeGem() divides
            // the DAI amount by the accumulated stability fee rate.
            // To circumvent this issue we will add 1 Wei to the amount to be paid
            // if there is enough investment token balance (DAI) to do it.
            if (debt.sub(amount) == 0 && balanceIT.sub(amount) >= 1) {
                amount = amount.add(1);
            }

            // Repay debt amount without unlocking collateral
            _freeCollateralAndRepayDai(0, amount);
        }
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
        }
    }

    function _takeYVaultProfit() internal {
        uint256 _debt = balanceOfDebt();
        uint256 _valueInVault = _valueOfInvestment();
        if (_debt >= _valueInVault) {
            return;
        }

        uint256 profit = _valueInVault.sub(_debt);
        uint256 ySharesToWithdraw = _investmentTokenToYShares(profit);
        if (ySharesToWithdraw > 0) {
            yVault.withdraw(ySharesToWithdraw, address(this), maxLoss);
            _swapKnownInInvestmentTokenToWant(balanceOfInvestmentToken());
        }
    }

    function _depositToMakerVault(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        _checkAllowance(gemJoinAdapter, address(want), amount);
        uint256 daiToMint = amount.mul(_getCollateralPrice()).mul(MAX_BPS).div(collateralizationRatio).div(WAD);
        _lockCollateralAndMintDai(amount, daiToMint);
    }

    // Returns maximum collateral to withdraw while maintaining the target collateralization ratio
    function _maxWithdrawal() internal view returns (uint256) {
        // Denominated in want
        uint256 totalCollateral = balanceOfMakerVault();

        // Denominated in investment token
        uint256 totalDebt = balanceOfDebt();

        // If there is no debt to repay we can withdraw all the locked collateral
        if (totalDebt == 0) {
            return totalCollateral;
        }

        // Min collateral in want that needs to be locked with the outstanding debt
        // Allow going to the lower rebalancing band
        uint256 minCollateral = collateralizationRatio.sub(rebalanceTolerance).mul(totalDebt).mul(WAD).div(_getCollateralPrice()).div(MAX_BPS);

        // If we are under collateralized then it is not safe for us to withdraw anything
        if (minCollateral > totalCollateral) {
            return 0;
        }

        return totalCollateral.sub(minCollateral);
    }

    // ----------------- PUBLIC BALANCES AND CALCS -----------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    ///@notice Returns investment token balance in the strategy
    function balanceOfInvestmentToken() public view returns (uint256) {
        return investmentToken.balanceOf(address(this));
    }

    ///@notice Returns debt balance in the maker vault
    function balanceOfDebt() public view returns (uint256) {
        return MakerDaiDelegateLib.debtForCdp(cdpId, ilk);
    }

    ///@notice Returns collateral balance in the maker vault
    function balanceOfMakerVault() public view returns (uint256) {
        return MakerDaiDelegateLib.balanceOfCdp(cdpId, ilk);
    }

    ///@notice Returns the DAI ceiling = amount of DAI that is available to be minted from Maker
    function balanceOfDaiAvailableToMint() public view returns (uint256) {
        return MakerDaiDelegateLib.balanceOfDaiAvailableToMint(ilk);
    }

    // Effective collateralization ratio of the vault
    function getCurrentMakerVaultRatio() public view returns (uint256) {
        return MakerDaiDelegateLib.getPessimisticRatioOfCdpWithExternalPrice(cdpId, ilk, _getCollateralPrice(), MAX_BPS);
    }

    // Check if current base fee is below an external oracle target base fee 
    function isBaseFeeAcceptable() internal view returns (bool) {
        return IBaseFee(baseFeeOracle).isCurrentBaseFeeAcceptable();
    }

    // ----------------- INTERNAL CALCS -----------------

    // Returns the minimum price available
    function _getCollateralPrice() internal view returns (uint256) {
        // Use price from spotter as base
        uint256 minPrice = MakerDaiDelegateLib.getSpotPrice(ilk);

        //check if OSMProxy is set & take most pessimistic collateral price:
        if (address(wantToUSDOSMProxy) != address(0)){
            // Peek the OSM to get current price
            try wantToUSDOSMProxy.read() returns (
                uint256 current,
                bool currentIsValid
            ) {
                if (currentIsValid && current > 0) {
                    minPrice = Math.min(minPrice, current);
                }
            } catch {
                // Ignore price peek()'d from OSM. Maybe we are no longer authorized.
            }

            // Peep the OSM to get future price
            try wantToUSDOSMProxy.foresight() returns (
                uint256 future,
                bool futureIsValid
            ) {
                if (futureIsValid && future > 0) {
                    minPrice = Math.min(minPrice, future);
                }
            } catch {
                // Ignore price peep()'d from OSM. Maybe we are no longer authorized.
            }
        }
        
        //check if chainlink oracle is set & take most pessimistic collateral price:
        if (address(chainlinkWantToUSDPriceFeed) != address(0)){
            // Non-ETH pairs have 8 decimals, so we need to adjust it to 18
            uint256 chainlinkPrice = uint256(chainlinkWantToUSDPriceFeed.latestAnswer()).mul(1e10);
            if (chainlinkPrice > 0) {
                minPrice = Math.min(minPrice, chainlinkPrice);
            }
        }

        // If price is set to 0 then we hope no liquidations are taking place
        // Emergency scenarios can be handled via manual debt repayment or by
        // granting governance access to the CDP
        require(minPrice > 0); // dev: invalid spot price

        // par is crucial to this calculation as it defines the relationship between DAI and
        // 1 unit of value in the price
        return minPrice.mul(RAY).div(MakerDaiDelegateLib.getDaiPar());
    }

    function _valueOfInvestment() internal view returns (uint256) {
        return
            yVault.balanceOf(address(this)).mul(yVault.pricePerShare()).div(10**yVault.decimals());
    }

    function _investmentTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(10**yVault.decimals()).div(yVault.pricePerShare());
    }

    function _lockCollateralAndMintDai(
        uint256 collateralAmount,
        uint256 daiToMint
    ) internal {
        MakerDaiDelegateLib.lockGemAndDraw(gemJoinAdapter, cdpId, collateralAmount, daiToMint, balanceOfDebt());
    }

    function _freeCollateralAndRepayDai(
        uint256 collateralAmount,
        uint256 daiToRepay
    ) internal {
        MakerDaiDelegateLib.wipeAndFreeGem(gemJoinAdapter, cdpId, collateralAmount, daiToRepay);
    }

    // ----------------- TOKEN CONVERSIONS -----------------

    function _convertInvestmentTokenToWant(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount.mul(WAD).div(_getCollateralPrice()).div(convertWantTo18Decimals);
    }

    //investmentToken --> want
    function _swapKnownInInvestmentTokenToWant(uint256 _amountIn) internal {
        if (_amountIn == 0 || address(investmentToken) == address(want)) {
            return;
        }
        uint256 slippagePrice;
        if (swapSlippage != 10000){
            slippagePrice = _getCollateralPrice().mul(DENOMINATOR.add(swapSlippage)).div(DENOMINATOR);
        }
        MakerDaiDelegateLib.swapKnownInInvestmentTokenToWant(swapRouterSelection, _amountIn, address(investmentToken), address(want), feeInvestmentTokenToMidUNIV3, feeMidToWantUNIV3, midTokenChoice, slippagePrice);
    }

    //want --> investmentToken
    function _swapKnownOutWantToInvestmentToken(uint256 _amountOut) internal {
        if (_amountOut == 0 || address(investmentToken) == address(want)) {
            return;
        }
        uint256 slippagePrice;
        if (swapSlippage != 10000){
            slippagePrice = _getCollateralPrice().mul(DENOMINATOR.sub(swapSlippage)).div(DENOMINATOR);
        }
        MakerDaiDelegateLib.swapKnownOutWantToInvestmentToken(swapRouterSelection, _amountOut, address(want), address(investmentToken), feeInvestmentTokenToMidUNIV3, feeMidToWantUNIV3, midTokenChoice, slippagePrice);
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }
        // approve and set up trade factory
        _checkAllowance(_tradeFactory, address(yVault), type(uint256).max);
        _checkAllowance(_tradeFactory, address(investmentToken), type(uint256).max);
        ITradeFactory(_tradeFactory).enable(address(want), address(investmentToken));
        ITradeFactory(_tradeFactory).enable(address(investmentToken), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(address(yVault)).safeApprove(tradeFactory, 0);
        investmentToken.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

}
