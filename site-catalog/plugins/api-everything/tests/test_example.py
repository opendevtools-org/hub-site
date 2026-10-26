from fastapi.testclient import TestClient

from app.main import app
from app.salesforce import list_url, salesforce_home


def test_page_calls_the_plugin_api() -> None:
    client = TestClient(app)
    html = client.get("/").text
    assert "fetch('/api/sites')" not in html
    assert "api/sites" in html


def test_sites_include_salesforce_cases() -> None:
    client = TestClient(app)
    response = client.get("/api/sites")
    assert response.status_code == 200
    sites = {site["id"]: site for site in response.json()["sites"]}
    api = sites["salesforce"]["apis"][0]
    assert api["id"] == "cases"
    assert [param["name"] for param in api["parameters"]] == ["indirizzo", "coda"]
    assert all(param["default"] == "" for param in api["parameters"])


def test_case_list_uses_the_typed_address() -> None:
    home = salesforce_home({"indirizzo": "https://esempio.lightning.force.com/lightning"})
    assert home == "https://esempio.lightning.force.com/lightning"
    assert list_url(home, "Team_Cases") == (
        "https://esempio.lightning.force.com/lightning/o/Case/list?filterName=Team_Cases"
    )


def test_missing_address_is_rejected() -> None:
    client = TestClient(app)
    response = client.post("/api/sites/salesforce/cases", json={})
    assert response.status_code == 502
    assert response.json()["detail"] == "Indica l'indirizzo di Salesforce."


def test_address_outside_salesforce_is_rejected() -> None:
    client = TestClient(app)
    response = client.post(
        "/api/sites/salesforce/cases",
        json={"indirizzo": "https://example.com", "coda": "Team_Cases"},
    )
    assert response.status_code == 502
    assert response.json()["detail"] == "Indirizzo non valido."


def test_salesforce_cases_returns_handler_result(monkeypatch) -> None:
    from app.main import _HANDLERS

    monkeypatch.setitem(
        _HANDLERS,
        ("salesforce", "cases"),
        lambda body: {
            "ok": True,
            "count": 1,
            "coda": body.get("coda") or "",
            "cases": [{"Case Id": "TS1", "Titolo": "Prova"}],
        },
    )
    client = TestClient(app)
    response = client.post("/api/sites/salesforce/cases", json={"coda": "Team_Cases"})
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 1
    assert body["cases"][0]["Case Id"] == "TS1"


def test_missing_queue_is_rejected() -> None:
    client = TestClient(app)
    response = client.post(
        "/api/sites/salesforce/cases",
        json={"indirizzo": "https://esempio.lightning.force.com"},
    )
    assert response.status_code == 502
    assert response.json()["detail"] == "Indica la coda."


def test_invalid_queue_is_rejected() -> None:
    client = TestClient(app)
    response = client.post(
        "/api/sites/salesforce/cases",
        json={
            "indirizzo": "https://esempio.lightning.force.com",
            "coda": "nome non valido",
        },
    )
    assert response.status_code == 502
    assert response.json()["detail"] == "Nome della coda non valido."
