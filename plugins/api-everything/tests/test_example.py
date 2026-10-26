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


def test_cve_advisory_lists_one_api_per_library() -> None:
    client = TestClient(app)
    response = client.get("/api/sites")
    sites = {site["id"]: site for site in response.json()["sites"]}
    apis = sites["cve-advisory"]["apis"]
    assert [api["id"] for api in apis] == [
        "openssl",
        "curl",
        "apache-cxf",
        "go",
        "kubernetes",
        "python",
        "semeru",
    ]
    by_id = {api["id"]: api for api in apis}
    version_fields = [
        {"name": "cve", "label": "CVE", "default": ""},
        {"name": "versione", "label": "Versione", "default": ""},
    ]
    for library in ("openssl", "curl", "apache-cxf", "semeru"):
        assert by_id[library]["parameters"] == version_fields
    for library in ("go", "kubernetes", "python"):
        assert by_id[library]["parameters"] == [{"name": "cve", "label": "CVE", "default": ""}]


def test_cve_advisory_requires_an_identifier() -> None:
    client = TestClient(app)
    response = client.post("/api/sites/cve-advisory/openssl", json={})
    assert response.status_code == 502
    assert response.json()["detail"] == "Indica il CVE."


def test_version_lists_the_cves_that_affect_it(monkeypatch) -> None:
    from app import cve_advisory

    def fake_affected(version: str, library: str):
        assert library == "openssl"
        assert version == "3.0.7"
        return [
            type(
                "Hit",
                (),
                {
                    "cve": "CVE-2023-0286",
                    "source": "openssl",
                    "url": "https://example.test/openssl",
                    "module": None,
                    "affected": "3.0.0 before 3.0.8",
                    "fixed_in": "3.0.8",
                    "severity": None,
                    "cvss_score": None,
                    "description": None,
                    "release_notes_url": None,
                },
            )()
        ]

    monkeypatch.setattr(cve_advisory, "affected", fake_affected)
    client = TestClient(app)
    response = client.post("/api/sites/cve-advisory/openssl", json={"versione": "3.0.7"})
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 1
    assert body["rows"][0]["CVE"] == "CVE-2023-0286"


def test_version_must_be_a_version() -> None:
    client = TestClient(app)
    response = client.post("/api/sites/cve-advisory/curl", json={"versione": "non-una-versione"})
    assert response.status_code == 502
    assert response.json()["detail"] == "Versione non valida."


def test_cve_advisory_rejects_a_bad_identifier() -> None:
    client = TestClient(app)
    response = client.post("/api/sites/cve-advisory/curl", json={"cve": "non-un-cve"})
    assert response.status_code == 502
    assert response.json()["detail"] == "Identificativo non valido."


def test_cve_advisory_uses_the_library_parser(monkeypatch) -> None:
    from app import cve_advisory

    def fake_lookup(cve_id: str, library: str):
        assert library == "openssl"
        return type(
            "Hit",
            (),
            {
                "cve": cve_id,
                "source": "openssl",
                "url": "https://example.test/openssl",
                "module": None,
                "affected": "3.0.0 before 3.0.8",
                "fixed_in": "3.0.8",
                "severity": None,
                "cvss_score": None,
                "description": None,
                "release_notes_url": None,
            },
        )()

    monkeypatch.setattr(cve_advisory, "lookup", fake_lookup)
    client = TestClient(app)
    response = client.post(
        "/api/sites/cve-advisory/openssl",
        json={"cve": "CVE-2023-0286"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 1
    assert body["rows"][0]["CVE"] == "CVE-2023-0286"
    assert body["rows"][0]["Corretto in"] == "3.0.8"


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
