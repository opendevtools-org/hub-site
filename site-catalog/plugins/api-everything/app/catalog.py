from __future__ import annotations

import json
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_SITES = _ROOT / "sites.json"


def load_sites() -> list[dict[str, object]]:
    data = json.loads(_SITES.read_text(encoding="utf-8"))
    sites = data.get("sites")
    if not isinstance(sites, list):
        return []
    return [site for site in sites if isinstance(site, dict)]


def find_api(site_id: str, api_id: str) -> tuple[dict[str, object], dict[str, object]] | None:
    for site in load_sites():
        if str(site.get("id") or "") != site_id:
            continue
        apis = site.get("apis")
        if not isinstance(apis, list):
            return None
        for api in apis:
            if isinstance(api, dict) and str(api.get("id") or "") == api_id:
                return site, api
        return None
    return None
