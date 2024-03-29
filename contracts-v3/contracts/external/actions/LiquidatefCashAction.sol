// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    AccountContext,
    PrimeRate,
    LiquidationFactors
} from "../../global/Types.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {AccountContextHandler} from "../../internal/AccountContextHandler.sol";
import {LiquidatefCash} from "../../internal/liquidation/LiquidatefCash.sol";
import {LiquidationHelpers} from "../../internal/liquidation/LiquidationHelpers.sol";
import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";

import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";

contract LiquidatefCashAction is ActionGuards {
    using AccountContextHandler for AccountContext;
    using PrimeRateLib for PrimeRate;
    using SafeInt256 for int256;

    /// @notice Calculates fCash local liquidation amounts, may settle account so this can be called off
    // chain using a static call
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be
    /// ordered descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity,
    /// zero will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function calculatefCashLocalLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateLocal(
                liquidateAccount,
                localCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
    }

    /// @notice Liquidates fCash using local currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity,
    /// zero will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function liquidatefCashLocal(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external payable nonReentrant returns (int256[] memory, int256) {
        require(fCashMaturities.length > 0);
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateLocal(
                liquidateAccount,
                localCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        LiquidatefCash.finalizefCashLiquidation(
            liquidateAccount,
            msg.sender,
            localCurrency,
            localCurrency,
            fCashMaturities,
            c
        );

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
    }

    /// @notice Calculates fCash cross currency liquidation, can be called via staticcall off chain
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashCurrency currency of fCash to purchase
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity, zero
    /// will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function calculatefCashCrossCurrencyLiquidation(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external nonReentrant returns (int256[] memory, int256) {
        uint256 blockTime = block.timestamp;
        LiquidatefCash.fCashContext memory c =
            _liquidateCrossCurrency(
                liquidateAccount,
                localCurrency,
                fCashCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
    }

    /// @notice Liquidates fCash across local to collateral currency
    /// @param liquidateAccount account to liquidate
    /// @param localCurrency local currency to liquidate
    /// @param fCashCurrency currency of fCash to purchase
    /// @param fCashMaturities array of fCash maturities in the local currency to purchase, must be ordered
    /// descending
    /// @param maxfCashLiquidateAmounts max notional of fCash to liquidate in corresponding maturity, zero
    /// will represent no maximum
    /// @return an array of the notional amounts of fCash to transfer, corresponding to fCashMaturities
    /// @return amount of local currency required from the liquidator
    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts
    ) external payable nonReentrant returns (int256[] memory, int256) {
        require(fCashMaturities.length > 0);
        uint256 blockTime = block.timestamp;

        LiquidatefCash.fCashContext memory c =
            _liquidateCrossCurrency(
                liquidateAccount,
                localCurrency,
                fCashCurrency,
                fCashMaturities,
                maxfCashLiquidateAmounts,
                blockTime
            );

        LiquidatefCash.finalizefCashLiquidation(
            liquidateAccount,
            msg.sender,
            localCurrency,
            fCashCurrency,
            fCashMaturities,
            c
        );

        return (c.fCashNotionalTransfers, c.localPrimeCashFromLiquidator);
    }

    function _liquidateLocal(
        address liquidateAccount,
        uint16 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) private returns (LiquidatefCash.fCashContext memory) {
        require(fCashMaturities.length == maxfCashLiquidateAmounts.length);
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            0
        );

        // prettier-ignore
        (
            int256 cashBalance,
            /* int256 nTokenBalance */,
            /* uint256 lastClaimTime */,
            /* uint256 accountIncentiveDebt */
        ) = BalanceHandler.getBalanceStorage(liquidateAccount, localCurrency, c.factors.localPrimeRate);
        // Cash balance is used if liquidating negative fCash
        c.localCashBalanceUnderlying = c.factors.localPrimeRate.convertToUnderlying(cashBalance);
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashLocal(
            liquidateAccount,
            localCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return c;
    }

    function _liquidateCrossCurrency(
        address liquidateAccount,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        uint256 blockTime
    ) private returns (LiquidatefCash.fCashContext memory) {
        require(fCashMaturities.length == maxfCashLiquidateAmounts.length); // dev: fcash maturity length mismatch
        LiquidatefCash.fCashContext memory c;
        (c.accountContext, c.factors, c.portfolio) = LiquidationHelpers.preLiquidationActions(
            liquidateAccount,
            localCurrency,
            fCashCurrency
        );
        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);

        LiquidatefCash.liquidatefCashCrossCurrency(
            liquidateAccount,
            fCashCurrency,
            fCashMaturities,
            maxfCashLiquidateAmounts,
            c,
            blockTime
        );

        return c;
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(SettleAssetsExternal));
    }
}
