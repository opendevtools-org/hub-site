#!/usr/bin/env python3
"""Export Salesforce case list to a copyable Google Docs HTML table.

Install Playwright in a virtual environment for live access:
    python -m venv .venv
    .venv/Scripts/python -m pip install -r cli/custom/salesforce_cases/requirements.txt
    .venv/Scripts/python -m playwright install chromium

Run from the repository root:
    .venv/Scripts/python cli/custom/salesforce_cases/main.py
    python cli/custom/salesforce_cases/main.py --html saved-page.html
    python cli/custom/salesforce_cases/main.py --format csv
    python cli/custom/salesforce_cases/main.py --cdp-url http://127.0.0.1:9222

The browser mode opens the list in a persistent, separate browser profile.
Sign in manually when prompted; no passwords are read by this script. Open
the HTML output, click "Copia tabella", and paste into Google Docs. The
default mode also updates ``cases.csv`` while preserving manually edited
columns. Every CSV export also writes a complete HTML version with the same
name beside it (cases.csv -> cases.html), including posts and manual notes.
--format csv skips only the separate Google Docs summary. Use --output to choose another
destination for the selected format (the default HTML mode still writes
``cases.csv`` next to this script). After each export, type A (Aggiorna) to
reload the list and details in the same authenticated session, or press Enter
to exit. Refresh also rereads the CSV to preserve intervening manual edits.
A reloads this file's extraction/export code from disk before refreshing,
without restarting the browser. Invalid code cancels that refresh and can be
fixed before retrying A. Browser startup, CLI arguments and the running session
loop still require a restart. Save edits before pressing A.
Use --cdp-url to attach to an existing Chromium browser with an explicitly
enabled CDP endpoint. Only script-created tabs are closed on exit; the attached
browser and its original tabs stay open. Keep CDP bound to localhost: it grants
control of authenticated pages. VS Code's shared browser page ID is NOT a CDP
URL; the integrated browser requires a compatible endpoint supplied by VS Code,
which is not documented as a public Python connection in its browser guide.
Live browser exports also collect the latest text post (including internal
posts, excluding automatic events) from IBM Enhanced Feed and the eight
Must Gather fields from its Visualforce iframe. Components are awaited before
reading. A detail extraction failure skips the export without updating files
and leaves the live session open so you can retry with A.
Offline --html exports only contain the list data and preserve saved details.
HTML and CSV use one multiline "Must Gather" column instead of "Ambiente".
Older CSV detail columns are consolidated automatically; legacy Ambiente
notes are preserved in Riassunto under "Ambiente precedente".
Must Gather layouts can omit fields: after the form has loaded, missing fields
are exported empty with a warning. Empty values are valid; unreadable fields
or a form that does not load still abort the export.
"""

from __future__ import annotations

import argparse
import csv
import sys
from contextlib import contextmanager, nullcontext
from html import escape
from html.parser import HTMLParser
from pathlib import Path
from types import ModuleType
from typing import Callable, Iterator
from urllib.parse import urljoin, urlsplit


DEFAULT_URL = "https://login.salesforce.com"
DEFAULT_HTML_OUTPUT = Path.home() / "riepilogo-cases.html"
DEFAULT_CSV_OUTPUT = Path(__file__).resolve().with_name("cases.csv")
LIST_LABEL = "Cases"
CASE_LINK_SELECTOR = ('table[aria-label="Cases"] tbody '
                      'tr[data-row-key-value^="500"] td[data-label="Case Number"] a[href]')


def case_list_selector() -> str:
    return f'table[aria-label="{LIST_LABEL}"]'


FIELDS = ("Last Modified Date", "Case Number", "Account Name", "Subject",
          "Days since last modification", "Severity Level", "Client Escalated",
          "Mission Team")
CSV_FIELDS = (
    "Case Id",
    "Customer",
    "Titolo",
    "Repo",
    "Giorni dall'ultima modifica",
    "Severity",
    "Scalato",
    "Mission Team",
    "Must Gather",
    "Ultimo post",
    "Riassunto",
    "Categoria",
    "Todo collegati",
    "Todo",
    "Eta",
)
CASE_DETAIL_FIELDS = (
    ("Prod", "Prod"),
    ("Fixpack", "Fixpack"),
    ("Product Version", "Product Version"),
    ("Operating System", "Operating System"),
    ("Component", "Component"),
    ("Service Type", "Service Type"),
    ("System Down", "System Down"),
    ("Business Impact", "How is this impacting your business?"),
)
MANUAL_FIELDS = (
    "Riassunto",
    "Categoria",
    "Todo collegati",
    "Todo",
    "Eta",
)


def format_must_gather(case: dict[str, str]) -> str:
    if not any(case.get(source, "") for _, source in CASE_DETAIL_FIELDS):
        return ""
    return "\n".join(
        f"{label}: {case.get(source, '')}" for label, source in CASE_DETAIL_FIELDS
    )


def to_csv_row(case: dict[str, str]) -> dict[str, str]:
    case_id = case.get("Case Number", "").strip()
    blue_diamond = case.get("Blue Diamond", "").strip().casefold() == "yes"
    repo = "Blue Diamond" if blue_diamond else "Ecurep" if case_id.upper().startswith("TS") else ""
    escalated_value = case.get("Client Escalated", "").strip().casefold()
    escalated = "Si" if escalated_value == "true" else "No" if escalated_value == "false" else ""
    return {
        "Case Id": case_id,
        "Customer": case.get("Account Name", ""),
        "Titolo": case.get("Subject", ""),
        "Repo": repo,
        "Giorni dall'ultima modifica": case.get("Days since last modification", ""),
        "Severity": case.get("Severity Level", "").split(" - ", 1)[0],
        "Scalato": escalated,
        "Mission Team": case.get("Mission Team", "").removeprefix("WLA: IWS "),
        "Ultimo post": case.get("Ultimo post", ""),
        "Must Gather": format_must_gather(case),
    }


def merge_live_cases(
    cases: list[dict[str, str]],
    existing_rows: list[dict[str, str]],
) -> list[dict[str, str]]:
    existing_by_id = {
        row.get("Case Id", "").strip(): row
        for row in existing_rows
        if row.get("Case Id", "").strip()
    }
    merged_rows = []
    for case in cases:
        row = to_csv_row(case)
        previous = existing_by_id.get(row["Case Id"], {})
        row.update({field: previous.get(field, "") for field in MANUAL_FIELDS})
        if "Ultimo post" not in case:
            row["Ultimo post"] = previous.get("Ultimo post", "")
        if not any(source in case for _, source in CASE_DETAIL_FIELDS):
            row["Must Gather"] = previous.get("Must Gather", format_must_gather({
                source: previous.get(output, "") for output, source in CASE_DETAIL_FIELDS
            }))
        if previous.get("Ambiente"):
            note = f"Ambiente precedente:\n{previous['Ambiente']}"
            row["Riassunto"] = "\n\n".join(filter(None, (row["Riassunto"], note)))
        merged_rows.append(row)

    def sort_key(row: dict[str, str]) -> tuple[int, str, int, int, str]:
        team = row["Mission Team"].strip()
        try:
            days_since_modification = int(row["Giorni dall'ultima modifica"])
        except ValueError:
            days_since_modification = 0
        return (
            0 if team.casefold() == "l3" else 1,
            team.casefold(),
            0 if row["Scalato"].casefold() == "si" else 1,
            -days_since_modification,
            row["Case Id"],
        )

    return sorted(merged_rows, key=sort_key)


class CaseTableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict[str, str]] = []
        self.row: dict[str, str] | None = None
        self.cell: str | None = None
        self.cell_depth = 0
        self.anchor_depth = 0
        self.text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "tr" and attributes.get("data-row-key-value", "").startswith("500"):
            self.row = {"id": attributes["data-row-key-value"] or ""}
        if self.row is None:
            return
        if self.cell is not None:
            if tag not in ("input", "br", "img", "hr", "meta", "source", "area", "link"):
                self.cell_depth += 1
            if tag == "a" and self.cell in ("Case Number", "Account Name", "Subject", "Mission Team"):
                self.anchor_depth += 1
                if self.cell == "Case Number":
                    self.row["href"] = attributes.get("href") or ""
            if self.cell == "Client Escalated" and tag == "lightning-icon":
                self.row[self.cell] = attributes.get("title") or ""
        elif tag in ("td", "th") and (attributes.get("data-label") in FIELDS or
                                       (attributes.get("data-label") or "").startswith("Blue Dia")):
            self.cell = ("Blue Diamond" if (attributes.get("data-label") or "").startswith("Blue Dia")
                         else attributes["data-label"])
            self.cell_depth = 1
            self.anchor_depth = 0
            self.text = []

    def handle_data(self, data: str) -> None:
        if self.cell is not None and (self.cell not in ("Case Number", "Account Name", "Subject", "Mission Team") or self.anchor_depth):
            self.text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if self.cell is not None:
            if tag == "a" and self.anchor_depth:
                self.anchor_depth -= 1
            self.cell_depth -= 1
            if self.cell_depth == 0:
                assert self.row is not None
                value = " ".join(" ".join(self.text).split())
                if self.cell != "Client Escalated" or self.cell not in self.row:
                    self.row[self.cell] = value
                self.cell = None
        elif tag == "tr" and self.row is not None:
            if self.row.get("Case Number"):
                self.rows.append(self.row)
            self.row = None


def parse_cases(source: str) -> list[dict[str, str]]:
    parser = CaseTableParser()
    parser.feed(source)
    return parser.rows


def render_table(rows: list[dict[str, str]], base_url: str) -> str:
    headers = ("Case Id", "Customer", "Titolo", "Repo", "Giorni dall'ultima modifica",
               "Severity", "Scalato", "Mission Team", "Must Gather", "Categoria", "Riepilogo")
    widths = (210, 210, 240, 130, 115, 70, 70, 90, 210, 110, 230)
    body = []
    for row in rows:
        case_id = escape(row.get("Case Number", ""))
        href = escape(urljoin(base_url, row.get("href", "")), quote=True)
        severity = row.get("Severity Level", "").split(" - ", 1)[0]
        team = row.get("Mission Team", "").removeprefix("WLA: IWS ")
        escalated = "Si" if row.get("Client Escalated", "").lower() == "true" else "No"
        repo = ("Blue Diamond" if row.get("Blue Diamond", "").strip().casefold() == "yes"
            else "Ecurep" if row.get("Case Number", "").upper().startswith("TS") else "")
        cells = (f'<a href="{href}">{case_id}</a>',
                 escape(row.get("Account Name", "")), escape(row.get("Subject", "")),
                 escape(repo), escape(row.get("Days since last modification", "")),
                 escape(severity), escalated, escape(team),
                 escape(row.get("Must Gather", format_must_gather(row))).replace("\n", "<br>"),
                 "", "")
        body.append("<tr>" + "".join(
            f'<td width="{width}" style="width:{width}px;border:1px solid #333;padding:7px;vertical-align:top">{cell}</td>'
            for width, cell in zip(widths, cells)) + "</tr>")
    return ("<!doctype html><html lang=\"it\"><meta charset=\"utf-8\">"
            "<title>Riepilogo Cases</title><style>body{font:14px Arial,sans-serif;margin:24px}"
            "table{border-collapse:collapse;width:100%}th,td{border:1px solid #333;"
            "padding:7px;text-align:left;vertical-align:top}th{background:#eee}"
            "button{margin-bottom:16px;padding:8px 12px}</style>"
            "<h1>Riepilogo Cases</h1>"
            "<button type=\"button\" onclick=\"copyTable()\">Copia tabella</button>"
            "<span id=\"copy-status\" role=\"status\"></span>"
            f'<table align="left" width="{sum(widths)}" style="width:{sum(widths)}px;table-layout:fixed;border-collapse:collapse;margin-left:0;margin-right:auto">'
            "<thead><tr>" + "".join(
                f'<th width="{width}" style="width:{width}px;border:1px solid #333;padding:7px;text-align:left;background:#eee">{escape(name)}</th>'
                for width, name in zip(widths, headers))
            + "</tr></thead><tbody>" + "".join(body) + "</tbody></table>"
            """<script>
            async function copyTable() {
                const table = document.querySelector('table');
                const status = document.getElementById('copy-status');
                const copy = table.cloneNode(true);
                const rows = Array.from(copy.tBodies[0].rows);
                rows.sort((a, b) =>
                    Number(b.cells[7].textContent.trim() === 'L3') -
                    Number(a.cells[7].textContent.trim() === 'L3') ||
                    a.cells[7].textContent.trim().localeCompare(b.cells[7].textContent.trim(), 'it') ||
                    Number(b.cells[6].textContent.trim().toLowerCase() === 'si') -
                    Number(a.cells[6].textContent.trim().toLowerCase() === 'si') ||
                    (Number(b.cells[4].textContent.trim()) || 0) - (Number(a.cells[4].textContent.trim()) || 0) ||
                    a.cells[0].textContent.localeCompare(b.cells[0].textContent)
                );
                rows.forEach(row => {
                    while (row.cells.length > 9) row.deleteCell(-1);
                    copy.tBodies[0].appendChild(row);
                });
                while (copy.tHead.rows[0].cells.length > 9) {
                    copy.tHead.rows[0].deleteCell(-1);
                }
                copy.setAttribute('align', 'left');
                copy.style.marginLeft = '0';
                copy.style.marginRight = 'auto';
                const richHtml = '<div style="text-align:left;margin:0;padding:0">' + copy.outerHTML + '</div>';
                const plainText = Array.from(copy.rows, row =>
                    Array.from(row.cells, cell => cell.textContent.trim()).join('\\t')
                ).join('\\n');
                try {
                    await navigator.clipboard.write([new ClipboardItem({
                        'text/html': new Blob([richHtml], {type: 'text/html'}),
                        'text/plain': new Blob([plainText], {type: 'text/plain'})
                    })]);
                    status.textContent = 'Tabella copiata.';
                    return;
                } catch (error) {
                    const range = document.createRange();
                    const container = document.createElement('div');
                    container.style.position = 'fixed';
                    container.style.left = '-9999px';
                    container.appendChild(copy);
                    document.body.appendChild(container);
                    range.selectNode(copy);
                    const selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    try {
                        if (document.execCommand('copy')) {
                            selection.removeAllRanges();
                            container.remove();
                            status.textContent = 'Tabella copiata.';
                            return;
                        }
                    } catch (ignored) {}
                    container.remove();
                    status.textContent = 'Copia bloccata: apri il file in Chrome o Edge.';
                }
            }
            </script></html>""")


def read_live_cases(page) -> list[dict[str, str]]:
    rows = []
    for record in page.locator(f'{case_list_selector()} tbody tr[data-row-key-value^="500"]').all():
        case_link = record.locator('[data-label="Case Number"] a[href]').first
        row = {"Case Number": case_link.inner_text().strip(),
               "href": case_link.get_attribute("href") or ""}
        for label in ("Account Name", "Subject", "Mission Team"):
            link = record.locator(f'[data-label="{label}"] a').first
            row[label] = link.inner_text().strip() if link.count() else ""
        for label in ("Days since last modification", "Severity Level"):
            cell = record.locator(f'[data-label="{label}"]').first
            row[label] = cell.inner_text().strip() if cell.count() else ""
        blue_diamond = record.locator('[data-label^="Blue Dia"]').first
        row["Blue Diamond"] = blue_diamond.inner_text().strip() if blue_diamond.count() else ""
        escalation = record.locator('[data-label="Client Escalated"] lightning-icon[title]').first
        row["Client Escalated"] = (escalation.get_attribute("title") or "") if escalation.count() else ""
        rows.append(row)
    return rows


def collect_live_cases(page) -> list[dict[str, str]]:
    table = page.locator(case_list_selector())
    expected = int(table.get_attribute("data-num-rows") or 0)
    collected: dict[str, dict[str, str]] = {}
    for _ in range(max(expected, 1) + 2):
        for row in read_live_cases(page):
            collected[row["href"]] = row
        if expected and len(collected) >= expected:
            break
        last_row = table.locator('tbody tr[data-row-key-value^="500"]').last
        last_row.evaluate("element => element.scrollIntoView({block: 'end'})")
        page.wait_for_timeout(250)
    if expected and len(collected) != expected:
        raise RuntimeError(f"Case caricati: {len(collected)} di {expected}. Scorri la lista e riprova.")
    cases = list(collected.values())
    detail_page = page.context.new_page()
    try:
        for index, case in enumerate(cases, start=1):
            print(f"Leggo dettagli {index}/{len(cases)}: {case['Case Number']}")
            detail_page.goto(urljoin(page.url, case["href"]), wait_until="domcontentloaded")
            read_case_details(detail_page, case)
    finally:
        detail_page.close()
    return cases


def read_case_details(page, case: dict[str, str]) -> None:
    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

    details: dict[str, str] = {}
    stage = "apertura Must Gather"
    try:
        gather_button = page.get_by_role("button", name="Must Gather", exact=True)
        gather_button.wait_for(state="visible")
        if gather_button.get_attribute("aria-expanded") == "false":
            gather_button.click()
        # Visualforce navigates the frame without setting the iframe src attribute.
        gather = next(
            (frame for frame in page.frames if "/apex/MustGatherLightning" in frame.url),
            None,
        )
        if gather is None:
            with page.expect_event(
                "framenavigated",
                predicate=lambda frame: "/apex/MustGatherLightning" in frame.url,
            ) as navigation:
                pass
            gather = navigation.value
        stage = "caricamento modulo Must Gather"
        gather.locator(".cMustGatherFieldReadOnly").first.wait_for(state="visible")
        for _, label in CASE_DETAIL_FIELDS:
            stage = f"Must Gather: {label}"
            field = gather.locator(".cMustGatherFieldReadOnly").filter(
                has=gather.get_by_text(label, exact=True)
            )
            value = field.locator(".slds-form-element__static")
            try:
                value.wait_for(state="attached")
            except PlaywrightTimeoutError:
                if field.count():
                    raise
                print(
                    f"Avviso {case['Case Number']}: campo Must Gather '{label}' "
                    "non presente nel modulo; esportato vuoto."
                )
                details[label] = ""
                continue
            details[label] = value.inner_text().strip()

        stage = "apertura Enhanced Feed"
        page.get_by_role("tab", name="Feed", exact=True).click()
        feed = page.locator("c-enhanced-feed:visible")
        sort = feed.locator('button[title="Newest First"], button[title="Oldest First"]')
        sort.wait_for(state="visible")
        if sort.get_attribute("title") == "Oldest First":
            sort.click()
            feed.locator('button[title="Newest First"]').wait_for(state="visible")

        stage = "ultimo post testuale di Enhanced Feed"
        body = feed.locator(
            'c-enhanced-feed-thread section.entry[data-text-post="true"] section.body'
        ).first
        body.wait_for(state="visible")
        details["Ultimo post"] = body.inner_text().strip()
        if not details["Ultimo post"]:
            raise RuntimeError(
                f"Case {case['Case Number']}: corpo del post vuoto; esportazione interrotta."
            )
    except PlaywrightTimeoutError as error:
        raise RuntimeError(
            f"Case {case['Case Number']}: timeout durante {stage}. "
            "Verifica accesso, caricamento e layout del Case; esportazione interrotta."
        ) from error
    case.update(details)


def write_csv_html(rows: list[dict[str, str]], csv_path: Path) -> Path:
    output_path = csv_path.with_suffix(".html")
    if output_path == csv_path:
        output_path = csv_path.with_name(csv_path.name + ".html")
    headers = "".join(f"<th>{escape(field)}</th>" for field in CSV_FIELDS)
    body = "".join(
        "<tr>" + "".join(
            f"<td>{escape(row.get(field, ''))}</td>" for field in CSV_FIELDS
        ) + "</tr>" for row in rows
    )
    document = (
        '<!doctype html><html lang="it"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        "<title>Cases</title><style>"
        "body{font:14px Arial,sans-serif;margin:24px}"
        "table{border-collapse:collapse}th,td{border:1px solid #bbb;padding:8px;"
        "text-align:left;vertical-align:top}"
        "th{position:sticky;top:0;background:#eee;white-space:nowrap}"
        "td{white-space:pre-wrap;overflow-wrap:anywhere;min-width:100px;max-width:600px}"
        "td:nth-child(9),td:nth-child(10),td:nth-child(11){min-width:320px}"
        "</style></head><body><h1>Cases</h1>"
        f"<p>{len(rows)} case</p><table><thead><tr>{headers}</tr></thead>"
        f"<tbody>{body}</tbody></table></body></html>"
    )
    output_path.write_text(document, encoding="utf-8")
    return output_path


def write_csv(cases: list[dict[str, str]], output_path: Path) -> list[dict[str, str]]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    existing_rows = []
    if output_path.exists():
        with output_path.open("r", encoding="utf-8-sig", newline="") as source:
            existing_rows = list(csv.DictReader(source))

    rows = merge_live_cases(cases, existing_rows)
    temp_path = output_path.with_suffix(output_path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    temp_path.replace(output_path)
    print(f"Esportati {len(cases)} case in {output_path.resolve()}")
    html_path = write_csv_html(rows, output_path)
    print(f"Versione HTML completa: {html_path.resolve()}")
    return rows


@contextmanager
def load_live_page(
    url: str, profile: Path, cdp_url: str | None = None,
) -> Iterator[Callable[[ModuleType], list[dict[str, str]]]]:
    try:
        from playwright.sync_api import (
            Error as PlaywrightError,
            TimeoutError as PlaywrightTimeoutError,
            sync_playwright,
        )
    except ImportError as error:
        raise SystemExit("Playwright non installato: vedi istruzioni all'inizio dello script.") from error

    with sync_playwright() as playwright:
        if cdp_url:
            browser = playwright.chromium.connect_over_cdp(cdp_url)
            contexts = browser.contexts
            matching = [
                context for context in contexts
                if any(urlsplit(tab.url).hostname == urlsplit(url).hostname for tab in context.pages)
            ]
            candidates = matching or contexts
            if len(candidates) != 1:
                raise RuntimeError(
                    "CDP: impossibile scegliere una sessione univoca. "
                    "Apri Salesforce in un solo contesto del browser."
                )
            context = candidates[0]
        else:
            context = playwright.chromium.launch_persistent_context(str(profile), headless=False)
        page = None
        try:
            page = context.new_page()

            def refresh(implementation: ModuleType) -> list[dict[str, str]]:
                try:
                    page.goto(url, wait_until="domcontentloaded")
                    try:
                        page.locator(implementation.CASE_LINK_SELECTOR).first.wait_for(state="attached", timeout=15000)
                    except PlaywrightTimeoutError:
                        input("Accedi a Salesforce nel browser e apri la coda, poi premi Invio qui...")
                        page.locator(implementation.CASE_LINK_SELECTOR).first.wait_for(state="attached", timeout=30000)
                    return implementation.collect_live_cases(page)
                except PlaywrightError as error:
                    raise RuntimeError(f"Lettura Salesforce fallita: {error}") from error

            yield refresh
        finally:
            if cdp_url:
                if page is not None and not page.is_closed():
                    page.close()
            else:
                context.close()


def ask_refresh() -> bool:
    while True:
        command = input(
            "Sessione aperta. [A] Aggiorna dati e codice; [Invio/Q] Esci "
            "(il browser collegato via CDP resta aperto): "
        ).strip().casefold()
        if command in ("a", "aggiorna"):
            return True
        if command in ("", "q", "esci"):
            return False
        print("Comando non valido: usa A per aggiornare oppure Invio/Q per uscire.")


def reload_code() -> ModuleType:
    path = Path(__file__).resolve()
    implementation = ModuleType("_salesforce_cases_live")
    implementation.__file__ = str(path)
    try:
        # Compile the source directly: rapid saves must not reuse cached bytecode.
        exec(compile(path.read_bytes(), str(path), "exec"), implementation.__dict__)
        for name in ("collect_live_cases", "export_cases"):
            if not callable(getattr(implementation, name, None)):
                raise ValueError(f"Funzione richiesta assente: {name}")
        if not isinstance(getattr(implementation, "CASE_LINK_SELECTOR", None), str):
            raise ValueError("CASE_LINK_SELECTOR assente o non valido")
    except Exception as error:
        raise RuntimeError(f"Ricaricamento codice fallito ({type(error).__name__}): {error}") from error
    print("Codice di estrazione/esportazione ricaricato.")
    return implementation


def export_cases(rows: list[dict[str, str]], arguments: argparse.Namespace) -> None:
    if arguments.format == "csv":
        write_csv(rows, arguments.output or DEFAULT_CSV_OUTPUT)
    else:
        output_path = arguments.output or DEFAULT_HTML_OUTPUT
        exported = {
            row["Case Id"]: row for row in write_csv(rows, DEFAULT_CSV_OUTPUT)
        }
        html_rows = [
            {**row, "Must Gather": exported[row["Case Number"]]["Must Gather"]}
            for row in rows
        ]
        if output_path.resolve() != DEFAULT_CSV_OUTPUT.with_suffix(".html").resolve():
            output_path.write_text(render_table(html_rows, arguments.url), encoding="utf-8")
        print(f"Esportati {len(rows)} case in {output_path.resolve()}")


def main() -> None:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    argument_parser.add_argument("--url", default=DEFAULT_URL, help="URL della lista Salesforce")
    argument_parser.add_argument("--html", type=Path, help="HTML salvato della tabella, senza login")
    argument_parser.add_argument(
        "--cdp-url", help="Endpoint CDP di un browser Chromium gia' aperto, es. http://127.0.0.1:9222"
    )
    argument_parser.add_argument("--format", choices=("html", "csv"), default="html")
    argument_parser.add_argument("--output", type=Path, help="Percorso del file generato")
    arguments = argument_parser.parse_args()
    if arguments.html and arguments.cdp_url:
        argument_parser.error("--html e --cdp-url non possono essere usati insieme.")
    source = (
        nullcontext(lambda implementation: implementation.parse_cases(
            arguments.html.read_text(encoding="utf-8")
        ))
        if arguments.html else load_live_page(
            arguments.url, Path.home() / ".salesforce-cases-browser", arguments.cdp_url
        )
    )
    implementation = sys.modules[__name__]
    reload_requested = False
    with source as refresh:
        while True:
            try:
                if reload_requested:
                    implementation = reload_code()
                rows = refresh(implementation)
                if not rows:
                    raise RuntimeError("Nessun case trovato nella tabella: verifica la pagina o il filtro.")
            except RuntimeError as error:
                if arguments.html:
                    raise SystemExit(str(error)) from error
                print(f"Esportazione non completata: {error}")
            else:
                implementation.export_cases(rows, arguments)
            if arguments.html or not ask_refresh():
                break
            reload_requested = True


if __name__ == "__main__":
    main()