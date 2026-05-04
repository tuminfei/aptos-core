from app.chain.client import ChainClient
from app.chain import view


async def get_power_overview(client: ChainClient) -> dict:
    current_period = await view.get_current_period(client)
    period_in_epochs = await view.get_power_period_in_epochs(client)
    retention = await view.get_retention_bps(client)
    operator = await view.get_power_operator(client)
    clock = await view.get_period_clock(client)

    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))
    clock_fields = view.period_clock_fields(period_in_epochs, clock)

    return {
        "current_period": current_period,
        "power_period_in_epochs": period_in_epochs,
        "retention_bps": retention,
        "operator": operator,
        "current_epoch": epoch,
        **clock_fields,
    }
