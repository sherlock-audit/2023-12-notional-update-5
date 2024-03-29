// SPDX-License-Identifier: BSUL-1.1
pragma solidity >=0.7.6;

/// @title All shared constants for the Notional system should be declared here.
library Constants {
    uint8 internal constant CETH_DECIMAL_PLACES = 8;

    // Token precision used for all internal balances, TokenHandler library ensures that we
    // limit the dust amount caused by precision mismatches
    int256 internal constant INTERNAL_TOKEN_PRECISION = 1e8;
    uint256 internal constant INCENTIVE_ACCUMULATION_PRECISION = 1e18;

    // ETH will be initialized as the first currency
    uint256 internal constant ETH_CURRENCY_ID = 1;
    uint8 internal constant ETH_DECIMAL_PLACES = 18;
    int256 internal constant ETH_DECIMALS = 1e18;
    address internal constant ETH_ADDRESS = address(0);
    // Used to prevent overflow when converting decimal places to decimal precision values via
    // 10**decimalPlaces. This is a safe value for int256 and uint256 variables. We apply this
    // constraint when storing decimal places in governance.
    uint256 internal constant MAX_DECIMAL_PLACES = 36;

    // Address of the account where fees are collected
    address internal constant FEE_RESERVE = 0x0000000000000000000000000000000000000FEE;
    // Address of the account where settlement funds are collected, this is only
    // used for off chain event tracking.
    address internal constant SETTLEMENT_RESERVE = 0x00000000000000000000000000000000000005e7;

    // Most significant bit
    bytes32 internal constant MSB =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    // Each bit set in this mask marks where an active market should be in the bitmap
    // if the first bit refers to the reference time. Used to detect idiosyncratic
    // fcash in the nToken accounts
    bytes32 internal constant ACTIVE_MARKETS_MASK = (
        MSB >> ( 90 - 1) | // 3 month
        MSB >> (105 - 1) | // 6 month
        MSB >> (135 - 1) | // 1 year
        MSB >> (147 - 1) | // 2 year
        MSB >> (183 - 1) | // 5 year
        MSB >> (211 - 1) | // 10 year
        MSB >> (251 - 1)   // 20 year
    );

    // Basis for percentages
    int256 internal constant PERCENTAGE_DECIMALS = 100;
    // Min Buffer Scale and Buffer Scale are used in ExchangeRate to increase the maximum
    // possible buffer values at the higher end of the uint8 range.
    int256 internal constant MIN_BUFFER_SCALE = 150;
    int256 internal constant BUFFER_SCALE = 10;
    // Max number of traded markets, also used as the maximum number of assets in a portfolio array
    uint256 internal constant MAX_TRADED_MARKET_INDEX = 7;
    // Max number of fCash assets in a bitmap, this is based on the gas costs of calculating free collateral
    // for a bitmap portfolio
    uint256 internal constant MAX_BITMAP_ASSETS = 20;
    uint256 internal constant FIVE_MINUTES = 300;

    // Internal date representations, note we use a 6/30/360 week/month/year convention here
    uint256 internal constant DAY = 86400;
    // We use six day weeks to ensure that all time references divide evenly
    uint256 internal constant WEEK = DAY * 6;
    uint256 internal constant MONTH = WEEK * 5;
    uint256 internal constant QUARTER = MONTH * 3;
    uint256 internal constant YEAR = QUARTER * 4;
    
    // These constants are used in DateTime.sol
    uint256 internal constant DAYS_IN_WEEK = 6;
    uint256 internal constant DAYS_IN_MONTH = 30;
    uint256 internal constant DAYS_IN_QUARTER = 90;

    // Offsets for each time chunk denominated in days
    uint256 internal constant MAX_DAY_OFFSET = 90;
    uint256 internal constant MAX_WEEK_OFFSET = 360;
    uint256 internal constant MAX_MONTH_OFFSET = 2160;
    uint256 internal constant MAX_QUARTER_OFFSET = 7650;

    // Offsets for each time chunk denominated in bits
    uint256 internal constant WEEK_BIT_OFFSET = 90;
    uint256 internal constant MONTH_BIT_OFFSET = 135;
    uint256 internal constant QUARTER_BIT_OFFSET = 195;

    // Number of decimal places that rates are stored in, equals 100%
    int256 internal constant RATE_PRECISION = 1e9;
    // Used for prime cash scalars
    uint256 internal constant SCALAR_PRECISION = 1e18;
    // Used in prime rate lib
    int256 internal constant DOUBLE_SCALAR_PRECISION = 1e36;
    // One basis point in RATE_PRECISION terms
    uint256 internal constant BASIS_POINT = uint256(RATE_PRECISION / 10000);
    // Used to when calculating the amount to deleverage of a market when minting nTokens
    uint256 internal constant DELEVERAGE_BUFFER = 300 * BASIS_POINT;
    // Used for scaling cash group factors
    uint256 internal constant FIVE_BASIS_POINTS = 5 * BASIS_POINT;
    // Used for residual purchase incentive and cash withholding buffer
    uint256 internal constant TEN_BASIS_POINTS = 10 * BASIS_POINT;
    // Used for max oracle rate
    uint256 internal constant FIFTEEN_BASIS_POINTS = 15 * BASIS_POINT;
    // Used in max rate calculations
    uint256 internal constant MAX_LOWER_INCREMENT = 150;
    uint256 internal constant MAX_LOWER_INCREMENT_VALUE = 150 * 25 * BASIS_POINT;
    uint256 internal constant TWENTY_FIVE_BASIS_POINTS = 25 * BASIS_POINT;
    uint256 internal constant ONE_HUNDRED_FIFTY_BASIS_POINTS = 150 * BASIS_POINT;

    // This is the ABDK64x64 representation of RATE_PRECISION
    // RATE_PRECISION_64x64 = ABDKMath64x64.fromUint(RATE_PRECISION)
    int128 internal constant RATE_PRECISION_64x64 = 0x3b9aca000000000000000000;

    uint8 internal constant FCASH_ASSET_TYPE          = 1;
    // Liquidity token asset types are 1 + marketIndex (where marketIndex is 1-indexed)
    uint8 internal constant MIN_LIQUIDITY_TOKEN_INDEX = 2;
    uint8 internal constant MAX_LIQUIDITY_TOKEN_INDEX = 8;
    uint8 internal constant VAULT_SHARE_ASSET_TYPE    = 9;
    uint8 internal constant VAULT_DEBT_ASSET_TYPE     = 10;
    uint8 internal constant VAULT_CASH_ASSET_TYPE     = 11;
    // Used for tracking legacy nToken assets
    uint8 internal constant LEGACY_NTOKEN_ASSET_TYPE  = 12;

    // Account context flags
    bytes1 internal constant HAS_ASSET_DEBT           = 0x01;
    bytes1 internal constant HAS_CASH_DEBT            = 0x02;
    bytes2 internal constant ACTIVE_IN_PORTFOLIO      = 0x8000;
    bytes2 internal constant ACTIVE_IN_BALANCES       = 0x4000;
    bytes2 internal constant UNMASK_FLAGS             = 0x3FFF;
    uint16 internal constant MAX_CURRENCIES           = uint16(UNMASK_FLAGS);

    // Equal to 100% of all deposit amounts for nToken liquidity across fCash markets.
    int256 internal constant DEPOSIT_PERCENT_BASIS    = 1e8;

    // nToken Parameters: there are offsets in the nTokenParameters bytes6 variable returned
    // in nTokenHandler. Each constant represents a position in the byte array.
    uint8 internal constant LIQUIDATION_HAIRCUT_PERCENTAGE = 0;
    uint8 internal constant CASH_WITHHOLDING_BUFFER = 1;
    uint8 internal constant RESIDUAL_PURCHASE_TIME_BUFFER = 2;
    uint8 internal constant PV_HAIRCUT_PERCENTAGE = 3;
    uint8 internal constant RESIDUAL_PURCHASE_INCENTIVE = 4;
    uint8 internal constant MAX_MINT_DEVIATION_LIMIT = 5;

    // Liquidation parameters
    // Default percentage of collateral that a liquidator is allowed to liquidate, will be higher if the account
    // requires more collateral to be liquidated
    int256 internal constant DEFAULT_LIQUIDATION_PORTION = 40;
    // Percentage of local liquidity token cash claim delivered to the liquidator for liquidating liquidity tokens
    int256 internal constant TOKEN_REPO_INCENTIVE_PERCENT = 30;

    // Pause Router liquidation enabled states
    bytes1 internal constant LOCAL_CURRENCY_ENABLED = 0x01;
    bytes1 internal constant COLLATERAL_CURRENCY_ENABLED = 0x02;
    bytes1 internal constant LOCAL_FCASH_ENABLED = 0x04;
    bytes1 internal constant CROSS_CURRENCY_FCASH_ENABLED = 0x08;

    // Requires vault accounts to enter a position for a minimum of 1 min
    // to mitigate strange behavior where accounts may enter and exit using
    // flash loans or other MEV type behavior.
    uint256 internal constant VAULT_ACCOUNT_MIN_TIME = 1 minutes;

    // Placeholder constant to mark the variable rate prime cash maturity
    uint40 internal constant PRIME_CASH_VAULT_MATURITY = type(uint40).max;

    // This represents the maximum percent change allowed before and after 
    // a rebalancing. 100_000 represents a 0.01% change
    // as a result of rebalancing. We should expect to never lose value as
    // a result of rebalancing, but some rounding errors may exist as a result
    // of redemption and deposit.
    int256 internal constant REBALANCING_UNDERLYING_DELTA_PERCENT = 100_000;

    // Ensures that the minimum total underlying held by the contract continues
    // to accrue interest so that money market oracle rates are properly updated
    // between rebalancing. With a minimum rebalancing cool down time of 6 hours
    // we would be able to detect at least 1 unit of accrual at 8 decimal precision
    // at an interest rate of 2.8 basis points (0.0288%) with 0.05e8 minimum balance
    // held in a given token.
    //
    //                          MIN_ACCRUAL * (86400 / REBALANCING_COOL_DOWN_HOURS)
    // MINIMUM_INTEREST_RATE =  ---------------------------------------------------
    //                                     MINIMUM_UNDERLYING_BALANCE
    int256 internal constant MIN_TOTAL_UNDERLYING_VALUE = 0.05e8;
}
