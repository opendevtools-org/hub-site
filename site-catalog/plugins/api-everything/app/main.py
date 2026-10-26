from __future__ import annotations

import logging
from typing import Any

from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import HTMLResponse

from app.catalog import find_api, load_sites
from app.salesforce import LoginRequired, read_cases

log = logging.getLogger("api-everything")
logging.basicConfig(level=logging.INFO)

app = FastAPI(title="api-everything", docs_url=None, redoc_url=None)

_HANDLERS = {
    ("salesforce", "cases"): read_cases,
}

_PAGE = """<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>api-everything</title>
  <style>
    body { font: 16px Arial, sans-serif; margin: 32px; color: #1a1a1a; background: #fafafa; }
    h1 { margin-bottom: 4px; }
    .lead { color: #444; }
    .site { background: #fff; border: 1px solid #ddd; border-radius: 8px; margin: 16px 0; }
    .site > button { width: 100%; text-align: left; background: #fff; border: 0;
      padding: 14px 16px; font: inherit; font-weight: 700; cursor: pointer; }
    .apis { display: none; border-top: 1px solid #eee; }
    .site.open .apis { display: block; }
    .op { padding: 14px 16px; border-top: 1px solid #f0f0f0; }
    .op:first-child { border-top: 0; }
    .method { display: inline-block; background: #1f8f4e; color: #fff; border-radius: 4px;
      padding: 2px 8px; font-size: 13px; margin-right: 8px; }
    .path { font-family: Consolas, monospace; font-size: 14px; }
    .desc { color: #444; margin: 8px 0; }
    label.field { display: block; margin: 8px 0; }
    label.field input { margin-left: 8px; padding: 6px 8px; font: inherit; min-width: 220px; }
    button.try { padding: 8px 14px; }
    .error { color: #9b1c1c; }
    table { border-collapse: collapse; margin-top: 12px; width: 100%; background: #fff; }
    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; vertical-align: top; }
  </style>
</head>
<body>
  <h1>api-everything</h1>
  <p class="lead">Apri un sito per vedere le API. Ogni chiamata usa i parametri e restituisce il risultato.</p>
  <div id="sites"></div>
  <script>
    function apiUrl(path) {
      return new URL(path, document.baseURI).href;
    }
    function showTable(target, rows) {
      target.replaceChildren();
      if (!rows.length) {
        target.textContent = 'Nessun caso.';
        return;
      }
      const keys = Object.keys(rows[0]);
      const table = document.createElement('table');
      const head = document.createElement('tr');
      for (const key of keys) {
        const cell = document.createElement('th');
        cell.textContent = key;
        head.appendChild(cell);
      }
      const thead = document.createElement('thead');
      thead.appendChild(head);
      table.appendChild(thead);
      const body = document.createElement('tbody');
      for (const row of rows) {
        const line = document.createElement('tr');
        for (const key of keys) {
          const cell = document.createElement('td');
          cell.textContent = String(row[key] ?? '');
          line.appendChild(cell);
        }
        body.appendChild(line);
      }
      table.appendChild(body);
      target.appendChild(table);
    }
    function addApi(list, site, api) {
      const block = document.createElement('article');
      block.className = 'op';
      const title = document.createElement('div');
      const method = document.createElement('span');
      method.className = 'method';
      method.textContent = api.method || 'POST';
      const path = document.createElement('span');
      path.className = 'path';
      path.textContent = '/api/sites/' + site.id + '/' + api.id;
      title.append(method, path);
      const name = document.createElement('strong');
      name.textContent = api.title;
      const desc = document.createElement('p');
      desc.className = 'desc';
      desc.textContent = api.description || '';
      const fields = document.createElement('div');
      const inputs = [];
      for (const param of api.parameters || []) {
        const label = document.createElement('label');
        label.className = 'field';
        label.textContent = param.label || param.name;
        const input = document.createElement('input');
        input.type = 'text';
        input.value = param.default || '';
        label.appendChild(input);
        fields.appendChild(label);
        inputs.push({ name: param.name, input: input });
      }
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'try';
      button.textContent = 'Prova';
      const status = document.createElement('p');
      const result = document.createElement('div');
      button.addEventListener('click', async () => {
        status.className = '';
        status.textContent = 'Chiamata in corso…';
        result.replaceChildren();
        const payload = {};
        for (const field of inputs) payload[field.name] = field.input.value.trim();
        try {
          const response = await fetch(apiUrl('api/sites/' + site.id + '/' + api.id), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
          });
          const answer = await response.json();
          if (!response.ok) {
            status.className = 'error';
            status.textContent = answer.detail || 'Lettura non riuscita.';
            return;
          }
          status.textContent = answer.count + ' righe.';
          showTable(result, answer.cases || []);
        } catch (error) {
          status.className = 'error';
          status.textContent = 'Lettura non riuscita.';
        }
      });
      block.append(title, name, desc, fields, button, status, result);
      list.appendChild(block);
    }
    function addSite(root, site) {
      const section = document.createElement('section');
      section.className = 'site';
      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.textContent = site.name;
      const list = document.createElement('div');
      list.className = 'apis';
      for (const api of site.apis) addApi(list, site, api);
      toggle.addEventListener('click', () => section.classList.toggle('open'));
      section.append(toggle, list);
      root.appendChild(section);
    }
    const root = document.getElementById('sites');
    fetch(apiUrl('api/sites')).then(response => {
      if (!response.ok) throw new Error('sites');
      return response.json();
    }).then(data => {
      for (const site of data.sites) addSite(root, site);
      if (!data.sites.length) root.textContent = 'Nessun sito definito.';
    }).catch(() => {
      root.textContent = 'Impossibile caricare i siti.';
    });
  </script>
</body>
</html>
"""


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def home() -> str:
    return _PAGE


@app.get("/api/sites")
def sites() -> dict[str, object]:
    listed = []
    for site in load_sites():
        apis = site.get("apis") if isinstance(site.get("apis"), list) else []
        listed.append(
            {
                "id": site.get("id"),
                "name": site.get("name"),
                "apis": [
                    {
                        "id": api.get("id"),
                        "method": api.get("method") or "POST",
                        "title": api.get("title") or api.get("id"),
                        "description": api.get("description") or "",
                        "parameters": [
                            {
                                "name": param.get("name"),
                                "label": param.get("label") or param.get("name"),
                                "default": param.get("default") or "",
                            }
                            for param in (api.get("parameters") or [])
                            if isinstance(param, dict) and param.get("name")
                        ],
                    }
                    for api in apis
                    if isinstance(api, dict)
                ],
            }
        )
    return {"sites": listed}


@app.post("/api/sites/{site_id}/{api_id}")
def call_api(
    site_id: str,
    api_id: str,
    body: dict[str, Any] | None = Body(default=None),
) -> dict[str, object]:
    found = find_api(site_id, api_id)
    if found is None:
        raise HTTPException(status_code=404, detail="API non definita")
    handler = _HANDLERS.get((site_id, api_id))
    if handler is None:
        raise HTTPException(status_code=404, detail="Questa API non ha ancora un'azione")
    try:
        return handler(body or {})
    except LoginRequired:
        raise HTTPException(
            status_code=409,
            detail="Accedi a Salesforce nel browser collegato e riprova.",
        ) from None
    except RuntimeError as error:
        log.info("site api failed site=%s api=%s", site_id, api_id)
        raise HTTPException(status_code=502, detail=str(error)) from None
    except Exception:
        log.exception("site api error site=%s api=%s", site_id, api_id)
        raise HTTPException(status_code=502, detail="Lettura non riuscita. Riprova.") from None
