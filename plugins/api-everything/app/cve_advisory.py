from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

LIBRARIES: tuple[tuple[str, str], ...] = (
    ("openssl", "OpenSSL"),
    ("curl", "curl"),
    ("apache-cxf", "Apache CXF"),
    ("go", "Go"),
    ("kubernetes", "Kubernetes"),
    ("python", "Python"),
    ("semeru", "Semeru"),
)


def _ensure_library() -> None:
    candidates = [
        Path("/app/framework-lib-script"),
        Path("/site/framework-lib-script"),
    ]
    for parent in Path(__file__).resolve().parents:
        candidates.append(parent / "framework-lib" / "python" / "script" / "src")
    for path in candidates:
        if (path / "homelab" / "cve" / "parsers" / "__init__.py").is_file():
            entry = str(path)
            if entry not in sys.path:
                sys.path.insert(0, entry)
            return
    raise RuntimeError("Lettura non riuscita. Riprova.")


def affected(version: str, library: str):
    _ensure_library()
    from homelab.cve.models import LookupOnlyError
    from homelab.cve.parsers import affected_cves_for_source
    from homelab.cve.sources import default_config

    source = default_config().libraries.get(library)
    if source is None:
        raise RuntimeError("Questa libreria non ha un advisory.")
    try:
        return affected_cves_for_source(version, source)
    except LookupOnlyError:
        raise RuntimeError("Per questa libreria indica il CVE.") from None


def lookup(cve_id: str, library: str):
    _ensure_library()
    from homelab.cve.parsers import search_cve_for_source
    from homelab.cve.sources import default_config

    source = default_config().libraries.get(library)
    if source is None:
        raise RuntimeError("Questa libreria non ha un advisory.")
    return search_cve_for_source(cve_id, source)


def _row(hit: Any) -> dict[str, str]:
    score = getattr(hit, "cvss_score", None)
    return {
        "CVE": hit.cve,
        "Fonte": hit.source or "",
        "Indirizzo": hit.url or "",
        "Modulo": hit.module or "",
        "Versioni interessate": hit.affected or "",
        "Corretto in": hit.fixed_in or "",
        "Gravità": hit.severity or "",
        "Punteggio": "" if score is None else str(score),
        "Descrizione": hit.description or "",
        "Note di rilascio": hit.release_notes_url or "",
    }


def read_advisory(library: str, body: dict[str, Any]) -> dict[str, object]:
    version = str(body.get("versione") or "").strip()
    if version:
        _ensure_library()
        from versions import version_tuple

        if version_tuple(version) is None:
            raise RuntimeError("Versione non valida.")
        hits = affected(version, library)
        return {"ok": True, "count": len(hits), "rows": [_row(hit) for hit in hits]}
    raw = str(body.get("cve") or "").strip()
    if not raw:
        raise RuntimeError("Indica il CVE.")
    _ensure_library()
    from homelab.cve.ids import CVE_OR_GO

    if CVE_OR_GO.fullmatch(raw) is None:
        raise RuntimeError("Identificativo non valido.")
    hit = lookup(raw.upper(), library)
    if hit is None:
        return {"ok": True, "count": 0, "rows": []}
    return {"ok": True, "count": 1, "rows": [_row(hit)]}
