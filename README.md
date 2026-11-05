# Enterprise site

This folder starts Hub from the published images. Nothing here is built from source.

Two Compose projects, started separately:

| Project | File | Role |
|---|---|---|
| `enterprise-backend` | `docker-compose.backend.yml` | Hub API |
| `enterprise-frontend` | `docker-compose.frontend.yml` | Hub web |

Images, tag `enterprise`:

- `ghcr.io/opendevtools-org/homelab-platform`
- `ghcr.io/opendevtools-org/homelab-hub`

Edition is `docker`. PKM is installed by Hub at startup from the public catalog.

## Start

```bash
cp .env.example .env
# Replace the two secrets in .env, then:

docker compose -f docker-compose.backend.yml up -d
docker compose -f docker-compose.frontend.yml up -d
```

The web UI listens on `127.0.0.1:3080`. Set `FE_BIND=0.0.0.0` in `.env` to open it on the machine address. The API stays on `127.0.0.1:8091`. Open the site by machine name or address, not only by localhost, so the page and the API stay on the same origin.

`.env` and `data/` stay on the machine. They are not part of this folder.
