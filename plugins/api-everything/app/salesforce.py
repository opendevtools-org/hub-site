"""Salesforce cases API. Reuses the company Playwright script."""

from __future__ import annotations

import csv
import importlib.util
import logging
import os
import re
import threading
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

log = logging.getLogger("api-everything")
_lock = threading.Lock()
_QUEUE = re.compile(r"[A-Za-z0-9_]{1,80}")
_ORG = re.compile(r"[a-z0-9](?:[a-z0-9.-]{0,200}[a-z0-9])?")


class LoginRequired(RuntimeError):
    pass


def _script_dir() -> Path:
    return Path(os.environ.get("SALESFORCE_DIR", "/opt/salesforce"))


def _load_script():
    path = _script_dir() / "main.py"
    if not path.is_file():
        raise RuntimeError("script Salesforce assente")
    spec = importlib.util.spec_from_file_location("salesforce_cases", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("script Salesforce illeggibile")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _existing_rows(script_dir: Path) -> list[dict[str, str]]:
    csv_path = script_dir / "cases.csv"
    if not csv_path.is_file():
        return []
    with csv_path.open("r", encoding="utf-8-sig", newline="") as source:
        return list(csv.DictReader(source))


def salesforce_home(body: dict[str, Any] | None) -> str:
    raw = ""
    if isinstance(body, dict):
        raw = str(body.get("indirizzo") or "").strip()
    if not raw:
        raise RuntimeError("Indica l'indirizzo di Salesforce.")
    parsed = urlsplit(raw)
    host = (parsed.hostname or "").lower().rstrip(".")
    org = host[: -len(".lightning.force.com")] if host.endswith(".lightning.force.com") else ""
    path = parsed.path.rstrip("/")
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or _ORG.fullmatch(org) is None
        or ".." in org
        or path not in ("", "/lightning")
    ):
        raise RuntimeError("Indirizzo non valido.")
    return f"https://{host}/lightning"


def queue_name(body: dict[str, Any] | None) -> str:
    raw = ""
    if isinstance(body, dict):
        raw = str(body.get("coda") or "").strip()
    if not raw:
        raise RuntimeError("Indica la coda.")
    if _QUEUE.fullmatch(raw) is None:
        raise RuntimeError("Nome della coda non valido.")
    return raw


def list_url(home: str, queue: str) -> str:
    return f"{home}/o/Case/list?filterName={queue}"


def list_label(queue: str) -> str:
    return queue.replace("_", " ")


def _read_with_browser(script, home: str, queue: str) -> list[dict[str, str]]:
    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
    from playwright.sync_api import sync_playwright

    label = list_label(queue)
    script.LIST_LABEL = label
    script.CASE_LINK_SELECTOR = (
        f'table[aria-label="{label}"] tbody '
        'tr[data-row-key-value^="500"] td[data-label="Case Number"] a[href]'
    )
    url = list_url(home, queue)
    script.DEFAULT_URL = url
    profile = Path(os.environ.get("BROWSER_PROFILE", "/data/profile"))
    cdp_url = os.environ.get("SALESFORCE_CDP_URL", "").strip() or "http://host.docker.internal:9222"
    headless = os.environ.get("BROWSER_HEADLESS", "1") != "0"
    profile.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as playwright:
        browser = None
        try:
            browser = playwright.chromium.connect_over_cdp(cdp_url)
            context = browser.contexts[0] if browser.contexts else browser.new_context()
            log.info("salesforce attached to the open browser")
        except Exception:
            log.info("salesforce open browser unavailable, starting one")
            browser = None
            context = playwright.chromium.launch_persistent_context(
                str(profile),
                headless=headless,
            )
        page = context.new_page()
        try:
            page.goto(url, wait_until="domcontentloaded")
            try:
                page.locator(script.CASE_LINK_SELECTOR).first.wait_for(
                    state="attached", timeout=15000
                )
            except PlaywrightTimeoutError as error:
                raise LoginRequired from error
            cases = script.collect_live_cases(page)
            return script.merge_live_cases(cases, _existing_rows(_script_dir()))
        finally:
            if not page.is_closed():
                page.close()
            if browser is None:
                context.close()


def read_cases(body: dict[str, Any] | None = None) -> dict[str, Any]:
    home = salesforce_home(body)
    queue = queue_name(body)
    with _lock:
        log.info("salesforce cases start queue=%s", queue)
        script = _load_script()
        rows = _read_with_browser(script, home, queue)
        log.info("salesforce cases ok count=%s", len(rows))
        return {"ok": True, "count": len(rows), "coda": queue, "cases": rows}
