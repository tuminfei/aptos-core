from app.chain.client import ChainClient
from app.chain import view
from app.models import watchlist


async def get_dapp_list(client: ChainClient) -> list[dict]:
    addresses = await watchlist.get_addresses("dapp")
    if not addresses:
        return []

    admins = [a["address"] for a in addresses]
    try:
        infos = await view.get_app_infos_by_admins(client, admins)
    except Exception:
        infos = []

    return infos
