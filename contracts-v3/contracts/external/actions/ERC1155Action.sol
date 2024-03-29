// SPDX-License-Identifier: BSUL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    AccountContext,
    PortfolioAsset,
    MarketParameters
} from '../../global/Types.sol';
import {StorageLayoutV1} from "../../global/StorageLayoutV1.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";

import {Emitter} from "../../internal/Emitter.sol";
import {AccountContextHandler} from "../../internal/AccountContextHandler.sol";
import {DateTime} from "../../internal/markets/DateTime.sol";
import {CashGroup} from "../../internal/markets/CashGroup.sol";
import {Market} from "../../internal/markets/Market.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {TransferAssets} from "../../internal/portfolio/TransferAssets.sol";
import {PortfolioHandler} from "../../internal/portfolio/PortfolioHandler.sol";
import {BitmapAssetsHandler} from "../../internal/portfolio/BitmapAssetsHandler.sol";
import {AssetHandler} from "../../internal/valuation/AssetHandler.sol";

import {FreeCollateralExternal} from "../FreeCollateralExternal.sol";
import {SettleAssetsExternal} from "../SettleAssetsExternal.sol";
import {ActionGuards} from "./ActionGuards.sol";

import {NotionalProxy} from "../../../interfaces/notional/NotionalProxy.sol";
import {IERC1155TokenReceiver} from "../../../interfaces/IERC1155TokenReceiver.sol";
import {nERC1155Interface} from "../../../interfaces/notional/nERC1155Interface.sol";
import {IVaultAccountHealth} from "../../../interfaces/notional/IVaultController.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract ERC1155Action is nERC1155Interface, ActionGuards {
    using SafeInt256 for int256;
    using AccountContextHandler for AccountContext;

    bytes4 internal constant ERC1155_ACCEPTED = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    bytes4 internal constant ERC1155_BATCH_ACCEPTED = bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155).interfaceId;
    }

    /// @notice Returns the balance of an ERC1155 id on an account.
    /// @param account account to get the id for
    /// @param id the ERC1155 id
    /// @return Balance of the ERC1155 id as an unsigned integer (negative fCash balances return zero)
    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        int256 notional = signedBalanceOf(account, id);
        return notional < 0 ? 0 : notional.toUint();
    }

    /// @notice Returns the balance of an ERC1155 id on an account.
    /// @param account account to get the id for
    /// @param id the ERC1155 id
    /// @return notional balance of the ERC1155 id as a signed integer
    function signedBalanceOf(address account, uint256 id) public view override returns (int256 notional) {
        if (nTokenHandler.nTokenAddress(Emitter.decodeCurrencyId(id)) == account) {
            // Special handling for nToken balances since they do not work like regular account balances.
            return _balanceInNToken(account, id);
        } else if (Emitter.isfCash(id)) {
            (uint16 currencyId, uint256 maturity, bool isfCashDebt) = Emitter.decodefCashId(id);
            AccountContext memory accountContext = AccountContextHandler.getAccountContext(account);

            if (accountContext.isBitmapEnabled()) {
                notional = _balanceInBitmap(account, accountContext.bitmapCurrencyId, currencyId, maturity);
            } else {
                notional = _balanceInArray(
                    PortfolioHandler.getSortedPortfolio(account, accountContext.assetArrayLength),
                    currencyId,
                    maturity
                );
            }

            // If asking for the fCash debt id, then return the positive amount or zero if it is not debt
            if (isfCashDebt) return notional < 0 ? notional.neg() : 0;
            return notional;
        } else {
            // In this case, the id is referencing a vault asset and we make a call back to retrieve the relevant
            // data. This is pretty inefficient for on chain calls but will work fine for off chain calls
            return IVaultAccountHealth(address(this)).signedBalanceOfVaultTokenId(account, id);
        }
    }

    /// @notice Returns the balance of a batch of accounts and ids.
    /// @param accounts array of accounts to get balances for
    /// @param ids array of ids to get balances for
    /// @return Returns an array of signed balances
    function signedBalanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (int256[] memory)
    {
        require(accounts.length == ids.length);
        int256[] memory amounts = new int256[](accounts.length);

        for (uint256 i; i < accounts.length; i++) {
            // This is pretty inefficient but gets the job done
            amounts[i] = signedBalanceOf(accounts[i], ids[i]);
        }

        return amounts;
    }

    /// @notice Returns the balance of a batch of accounts and ids. WARNING: negative fCash balances are represented
    /// as zero balances in the array. 
    /// @param accounts array of accounts to get balances for
    /// @param ids array of ids to get balances for
    /// @return Returns an array of unsigned balances
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory)
    {
        require(accounts.length == ids.length);
        uint256[] memory amounts = new uint256[](accounts.length);

        for (uint256 i; i < accounts.length; i++) {
            // This is pretty inefficient but gets the job done
            amounts[i] = balanceOf(accounts[i], ids[i]);
        }

        return amounts;
    }

    /// @dev Returns the balance from a bitmap given the id
    function _balanceInBitmap(
        address account,
        uint256 bitmapCurrencyId,
        uint16 currencyId,
        uint256 maturity
    ) internal view returns (int256) {
        if (currencyId == 0 || currencyId != bitmapCurrencyId) {
            return 0;
        } else {
            return BitmapAssetsHandler.getifCashNotional(account, currencyId, maturity);
        }
    }

    /// @dev Searches an array for the matching asset
    function _balanceInArray(
        PortfolioAsset[] memory portfolio, uint16 currencyId, uint256 maturity
    ) internal pure returns (int256) {
        for (uint256 i; i < portfolio.length; i++) {
            PortfolioAsset memory asset = portfolio[i];
            if (
                asset.currencyId == currencyId &&
                asset.maturity == maturity &&
                asset.assetType == Constants.FCASH_ASSET_TYPE
            ) return asset.notional;
        }

        return 0;
    }

    function _balanceInNToken(address nTokenAccount, uint256 id) internal view returns (int256 balance) {
        (uint16 currencyId, uint256 maturity, bool isfCashDebt) = Emitter.decodefCashId(id);
        // Allow the balanceOf to search all of the max markets, if the returned market index exceeds the asset array length then,
        // the function will return a zero balance rather than revert.
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(Constants.MAX_TRADED_MARKET_INDEX, maturity, block.timestamp);

        if (isIdiosyncratic || isfCashDebt) {
            // If asking for an idiosyncratic market or fCash debt, then the fCash balance will only be in the bitmap
            balance = _balanceInBitmap(nTokenAccount, currencyId, currencyId, maturity);

            // Flip the sign to positive if asking for the fCash debt
            if (isfCashDebt) return balance < 0 ? balance.neg() : 0;
        } else {
            // If asking for the positive fCash balance, that means we need to load the market and get the cash claims
            (/* */, /* */, /* */, uint8 assetArrayLength, /* */) = nTokenHandler.getNTokenContext(nTokenAccount);

            // Market index is beyond the maximum length of the market so return a zero balance.
            if (marketIndex > assetArrayLength) return 0;

            PortfolioAsset[] memory liquidityTokens = PortfolioHandler.getSortedPortfolio(nTokenAccount, assetArrayLength);
            MarketParameters memory market;
            // rateOracleTimeWindow is not used here, so it is set to 1 to save some gas. This also only loads the current settlement
            // market, if markets are not initialized this will not return the proper balance.
            Market.loadMarket(market, currencyId, maturity, block.timestamp, true, 1);
            if (market.totalLiquidity == 0) return 0;

            (/* int256 cashClaim */, balance) = AssetHandler.getCashClaims(liquidityTokens[marketIndex - 1], market);
        }
    }

    /// @notice Transfer of a single fCash or liquidity token asset between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param id ERC1155 id of the asset
    /// @param amount amount to transfer
    /// @param data arbitrary data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferSingle, emit:AccountContextUpdate, emit:AccountSettled
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external payable override {
        // NOTE: there is no re-entrancy guard on this method because that would prevent a callback in 
        // _checkPostTransferEvent. The external call to the receiver is done at the very end after all stateful
        // updates have occurred.
        _validateAccounts(from, to);

        // When amount is set to zero this method can be used as a way to execute trades via a transfer operator
        AccountContext memory fromContext;
        if (amount > 0) {
            PortfolioAsset[] memory assets = new PortfolioAsset[](1);
            PortfolioAsset memory asset = assets[0];

            // Only Positive fCash is supported in ERC1155 transfers
            _decodeTofCashAsset(id, asset);

            // This ensures that asset.notional is always a positive amount
            asset.notional = SafeInt256.toInt(amount);
            _requireValidMaturity(asset.currencyId, asset.maturity, block.timestamp);

            // prettier-ignore
            (fromContext, /* toContext */) = _transfer(from, to, assets);
        } else {
            fromContext = AccountContextHandler.getAccountContext(from);
        }

        // toContext is always empty here because we cannot have bidirectional transfers in `safeTransferFrom`
        AccountContext memory toContext;
        _checkPostTransferEvent(from, to, fromContext, toContext, data, false);

        // Do this external call at the end to prevent re-entrancy
        if (Address.isContract(to)) {
            require(
                IERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data) ==
                    ERC1155_ACCEPTED,
                "Not accepted"
            );
        }
    }

    /// @notice Transfer of a batch of fCash or liquidity token assets between accounts. Allows `from` account to transfer more fCash
    /// than they have as long as they pass a subsequent free collateral check. This enables OTC trading of fCash assets.
    /// @param from account to transfer from
    /// @param to account to transfer to
    /// @param ids ERC1155 ids of the assets
    /// @param amounts amounts to transfer
    /// @param data arbitrary data passed to ERC1155Receiver (if contract) and if properly specified can be used to initiate
    /// a trading action on Notional for the `from` address
    /// @dev emit:TransferBatch, emit:AccountContextUpdate, emit:AccountSettled
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external payable override {
        // NOTE: there is no re-entrancy guard on this method because that would prevent a callback in 
        // _checkPostTransferEvent. The external call to the receiver is done at the very end.
        _validateAccounts(from, to);

        (PortfolioAsset[] memory assets, bool toTransferNegative) = _decodeToAssets(ids, amounts);
        // When doing a bidirectional transfer must ensure that the `to` account has given approval
        // to msg.sender as well.
        if (toTransferNegative) require(isApprovedForAll(to, msg.sender), "Unauthorized");

        (AccountContext memory fromContext, AccountContext memory toContext) = _transfer(
            from,
            to,
            assets
        );

        _checkPostTransferEvent(from, to, fromContext, toContext, data, toTransferNegative);

        // Do this at the end to prevent re-entrancy
        if (Address.isContract(to)) {
            require(
                IERC1155TokenReceiver(to).onERC1155BatchReceived(
                    msg.sender,
                    from,
                    ids,
                    amounts,
                    data
                ) == ERC1155_BATCH_ACCEPTED,
                "Not accepted"
            );
        }
    }

    /// @dev Validates accounts on transfer
    function _validateAccounts(address from, address to) private view {
        // Cannot transfer to self, cannot transfer to zero address
        require(from != to && to != address(0) && to != address(this), "Invalid address");
        // Authentication is valid
        require(msg.sender == from || isApprovedForAll(from, msg.sender), "Unauthorized");
        // nTokens will not accept transfers because they do not implement the ERC1155
        // receive method

        // Defensive check to ensure that an authorized operator does not call these methods
        // with an invalid `from` account
        requireValidAccount(from);
    }

    /// @notice Decodes ids and amounts to PortfolioAsset objects
    /// @param ids array of ERC1155 ids
    /// @param amounts amounts to transfer
    /// @return array of portfolio asset objects
    function decodeToAssets(uint256[] calldata ids, uint256[] calldata amounts)
        external
        view
        override
        returns (PortfolioAsset[] memory)
    {
        // prettier-ignore
        (PortfolioAsset[] memory assets, /* */) = _decodeToAssets(ids, amounts);
        return assets;
    }

    function _decodeTofCashAsset(uint256 id, PortfolioAsset memory asset) private pure {
        require(Emitter.isfCash(id), "Only fCash Transfer");
        bool isfCashDebt;
        (asset.currencyId, asset.maturity, isfCashDebt) = Emitter.decodefCashId(id);
        // Technically debt is transferrable inside this method, but for clarity and backwards compatibility
        // this restriction is applied here.
        require(!isfCashDebt, "No Debt Transfer");

        asset.assetType = Constants.FCASH_ASSET_TYPE;
    }

    function _decodeToAssets(uint256[] calldata ids, uint256[] calldata amounts)
        private
        view
        returns (PortfolioAsset[] memory, bool)
    {
        require(ids.length == amounts.length);
        bool toTransferNegative = false;
        PortfolioAsset[] memory assets = new PortfolioAsset[](ids.length);

        for (uint256 i; i < ids.length; i++) {
            // Require that ids are not duplicated, there is no valid reason to have duplicate ids
            if (i > 0) require(ids[i] > ids[i - 1], "IDs must be sorted");

            PortfolioAsset memory asset = assets[i];
            _decodeTofCashAsset(ids[i], assets[i]);

            _requireValidMaturity(asset.currencyId, asset.maturity, block.timestamp);
            // Although amounts is encoded as uint256 we allow it to be negative here. This will
            // allow for bidirectional transfers of fCash. Internally fCash assets are always stored
            // as int128 (for bitmap portfolio) or int88 (for array portfolio) so there is no potential
            // that a uint256 value that is greater than type(int256).max would actually valid.
            asset.notional = int256(amounts[i]);
            // If there is a negative transfer we mark it as such, this will force us to do a free collateral
            // check on the `to` address as well.
            if (asset.notional < 0) toTransferNegative = true;
        }

        return (assets, toTransferNegative);
    }

    /// @notice Encodes parameters into an ERC1155 id, this method always returns an fCash id
    /// @param currencyId currency id of the asset
    /// @param maturity timestamp of the maturity
    /// @return ERC1155 id
    function encodeToId(
        uint16 currencyId,
        uint40 maturity,
        uint8 /* assetType */
    ) external pure override returns (uint256) {
        return Emitter.encodefCashId(currencyId, maturity, 0);
    }

    /// @dev Ensures that all maturities specified are valid for the currency id (i.e. they do not
    /// go past the max maturity date)
    function _requireValidMaturity(
        uint256 currencyId,
        uint256 maturity,
        uint256 blockTime
    ) private view {
        require(
            DateTime.isValidMaturity(CashGroup.getMaxMarketIndex(currencyId), maturity, blockTime),
            "Invalid maturity"
        );
    }

    /// @dev Internal asset transfer event between accounts
    function _transfer(
        address from,
        address to,
        PortfolioAsset[] memory assets
    ) internal returns (AccountContext memory, AccountContext memory) {
        AccountContext memory toContext = AccountContextHandler.getAccountContext(to);
        AccountContext memory fromContext = AccountContextHandler.getAccountContext(from);
        
        // NOTE: context returned are in different memory locations
        (fromContext, toContext) = SettleAssetsExternal.transferAssets(
            from, to, fromContext, toContext, assets
        );

        fromContext.setAccountContext(from);
        toContext.setAccountContext(to);

        return (fromContext, toContext);
    }

    /// @dev Checks post transfer events which will either be initiating one of the batch trading events or a free collateral
    /// check if required.
    function _checkPostTransferEvent(
        address from,
        address to,
        AccountContext memory fromContext,
        AccountContext memory toContext,
        bytes calldata data,
        bool toTransferNegative
    ) internal {
        bytes4 sig = 0;
        address transactedAccount = address(0);
        if (data.length >= 32) {
            // Method signature is not abi encoded so decode to bytes32 first and take the first 4 bytes. This works
            // because all the methods we want to call below require more than 32 bytes in the calldata
            bytes32 tmp = abi.decode(data, (bytes32));
            sig = bytes4(tmp);
        }

        // These are the only four methods allowed to occur in a post transfer event. These actions allow `from`
        // accounts to take any sort of trading action as a result of their transfer. All of these actions will
        // handle checking free collateral so no additional check is necessary here.
        if (
            sig == NotionalProxy.nTokenRedeem.selector ||
            sig == NotionalProxy.batchLend.selector ||
            sig == NotionalProxy.batchBalanceAction.selector ||
            sig == NotionalProxy.batchBalanceAndTradeAction.selector
        ) {
            transactedAccount = abi.decode(data[4:36], (address));
            // Ensure that the "transactedAccount" parameter of the call is set to the from address or the
            // to address. If it is the "to" address then ensure that the msg.sender has approval to
            // execute operations
            require(
                transactedAccount == from ||
                    (transactedAccount == to && isApprovedForAll(to, msg.sender)),
                "Unauthorized call"
            );

            // We can only call back to Notional itself at this point, account context is already
            // stored and all three of the whitelisted methods above will check free collateral.
            (bool status, bytes memory result) = address(this).call{value: msg.value}(data);
            require(status, _getRevertMsg(result));
        }

        // The transacted account will have its free collateral checked above so there is
        // no need to recheck here.
        // If transactedAccount == 0 then will check fc
        // If transactedAccount == to then will check fc
        // If transactedAccount == from then will skip, prefer call above
        if (transactedAccount != from && fromContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(from);
        }

        // Check free collateral if the `to` account has taken on a negative fCash amount
        // If toTransferNegative is false then will not check
        // If transactedAccount == 0 then will check fc
        // If transactedAccount == from then will check fc
        // If transactedAccount == to then will skip, prefer call above
        if (toTransferNegative && transactedAccount != to && toContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(to);
        }
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }

    /// @notice Allows an account to set approval for an operator
    /// @param operator address of the operator
    /// @param approved state of the approval
    /// @dev emit:ApprovalForAll
    function setApprovalForAll(address operator, bool approved) external override {
        accountAuthorizedTransferOperator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Checks approval state for an account, will first check if global transfer operator is enabled
    /// before falling through to an account specific transfer operator.
    /// @param account address of the account
    /// @param operator address of the operator
    /// @return true for approved
    function isApprovedForAll(address account, address operator)
        public
        view
        override
        returns (bool)
    {
        if (globalTransferOperator[operator]) return true;

        return accountAuthorizedTransferOperator[account][operator];
    }

    /// @notice Get a list of deployed library addresses (sorted by library name)
    function getLibInfo() external pure returns (address, address) {
        return (address(FreeCollateralExternal), address(SettleAssetsExternal));
    }
}
