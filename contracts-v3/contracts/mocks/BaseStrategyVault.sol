// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {Token, TokenType} from "../global/Types.sol";
import {IStrategyVault} from "../../interfaces/notional/IStrategyVault.sol";
import {NotionalProxy} from "../../interfaces/notional/NotionalProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// NOTE: the canonical BaseStrategyVault is in the https://github.com/notional-finance/leveraged-vaults repo,
// this version is used for testing purposes only.
abstract contract BaseStrategyVault is IStrategyVault {
    using SafeERC20 for ERC20;

    /** These view methods need to be implemented by the vault */
    function convertStrategyToUnderlying(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) public view virtual override returns (int256 underlyingValue);

    function strategy() external view virtual override returns (bytes4 strategyId);

    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal virtual returns (uint256 strategyTokensMinted);

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) internal virtual returns (uint256 tokensFromRedeem);

    uint16 internal immutable BORROW_CURRENCY_ID;
    ERC20 internal immutable UNDERLYING_TOKEN;
    bool internal immutable UNDERLYING_IS_ETH;
    NotionalProxy public immutable NOTIONAL;

    uint8 internal constant INTERNAL_TOKEN_DECIMALS = 8;
    string public override name;

    function decimals() public pure override returns (uint8) {
        return INTERNAL_TOKEN_DECIMALS;
    }

    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    constructor(
        string memory name_,
        address notional_,
        uint16 borrowCurrencyId_
    ) {
        name = name_;
        NOTIONAL = NotionalProxy(notional_);
        BORROW_CURRENCY_ID = borrowCurrencyId_;

        (
            Token memory assetToken,
            Token memory underlyingToken
        ) = NotionalProxy(notional_).getCurrency(borrowCurrencyId_);

        address underlyingAddress = assetToken.tokenType == TokenType.NonMintable
            ? assetToken.tokenAddress
            : underlyingToken.tokenAddress;
        UNDERLYING_TOKEN = ERC20(underlyingAddress);
        UNDERLYING_IS_ETH = underlyingToken.tokenType == TokenType.Ether;
    }

    // External methods are authenticated to be just Notional
    function depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) external payable override onlyNotional returns (uint256 strategyTokensMinted) {
        return _depositFromNotional(account, deposit, maturity, data);
    }

    function redeemFromNotional(
        address account,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) external override onlyNotional returns (uint256 transferToReceiver) {
        uint256 tokensFromRedeem = _redeemFromNotional(
            account, strategyTokens, maturity, underlyingToRepayDebt, data
        );

        uint256 transferToNotional;
        if (account == address(this) || tokensFromRedeem <= underlyingToRepayDebt) {
            // It may be the case that insufficient tokens were redeemed to repay the debt. If this
            // happens the Notional will attempt to recover the shortfall from the account directly.
            // This can happen if an account wants to reduce their leverage by paying off debt but
            // does not want to sell strategy tokens to do so.
            // The other situation would be that the vault is calling redemption to deleverage or
            // settle. In that case all tokens go back to Notional.
            transferToNotional = tokensFromRedeem;
        } else {
            transferToNotional = underlyingToRepayDebt;
            transferToReceiver = tokensFromRedeem - underlyingToRepayDebt;
        }

        if (UNDERLYING_IS_ETH) {
            if (transferToReceiver > 0) payable(receiver).transfer(transferToReceiver);
            if (transferToNotional > 0) payable(address(NOTIONAL)).transfer(transferToNotional);
        } else {
            if (transferToReceiver > 0) UNDERLYING_TOKEN.safeTransfer(receiver, transferToReceiver);
            if (transferToNotional > 0)
                UNDERLYING_TOKEN.safeTransfer(address(NOTIONAL), transferToNotional);
        }
    }

    function convertVaultSharesToPrimeMaturity(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) external override onlyNotional returns (uint256 primeStrategyTokens) {
        return _convertVaultSharesToPrimeMaturity(account, strategyTokens, maturity);
    }

    function _convertVaultSharesToPrimeMaturity(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) internal virtual returns (uint256 primeStrategyTokens) {
        // Can be overridden if required
        revert();
    }

    receive() external payable {
        // Allow ETH transfers to succeed
    }
}