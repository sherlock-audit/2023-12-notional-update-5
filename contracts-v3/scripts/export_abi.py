import json

from brownie import SecondaryRewarder
from brownie.project import ContractsV3Project


def main():
    NotionalABI = ContractsV3Project._build.get("NotionalProxy")["abi"]
    with open("abi/Notional.json", "w") as f:
        json.dump(NotionalABI, f, sort_keys=True, indent=4)

    with open("abi/SecondaryRewarder.json", "w") as f:
        json.dump(SecondaryRewarder.abi, f, sort_keys=True, indent=4)

    StrategyVaultABI = ContractsV3Project._build.get("IStrategyVault")["abi"]
    with open("abi/IStrategyVault.json", "w") as f:
        json.dump(StrategyVaultABI, f, sort_keys=True, indent=4)

    ERC4626ABI = ContractsV3Project._build.get("BaseERC4626Proxy")["abi"]
    with open("abi/ERC4626.json", "w") as f:
        json.dump(ERC4626ABI, f, sort_keys=True, indent=4)

    PrimeCashHoldingsOracle = ContractsV3Project._build.get("IPrimeCashHoldingsOracle")["abi"]
    with open("abi/PrimeCashHoldingsOracle.json", "w") as f:
        json.dump(PrimeCashHoldingsOracle, f, sort_keys=True, indent=4)

    LeveragedNTokenAdapater = ContractsV3Project._build.get("LeveragedNTokenAdapter")["abi"]
    with open("abi/LeveragedNTokenAdapter.json", "w") as f:
        json.dump(LeveragedNTokenAdapater, f, sort_keys=True, indent=4)