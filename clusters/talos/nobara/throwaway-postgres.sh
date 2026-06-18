#!/usr/bin/env bash
# Throwaway Postgres on Nobara — matches the CNPG operand (PG 18) so v4
# migration scripts validated here behave identically on the cluster.
# Podman ships on Nobara; rootless is fine. DISPOSABLE BY DESIGN:
#   podman rm -f cartarch-pg && podman volume rm cartarch-pg-data
set -euo pipefail
PG_MAJOR=18

podman volume create cartarch-pg-data >/dev/null 2>&1 || true
podman run -d --name cartarch-pg \
  -e POSTGRES_USER=cartarch \
  -e POSTGRES_PASSWORD=throwaway-local-only \
  -e POSTGRES_DB=cartarch \
  -p 127.0.0.1:5432:5432 \
  -v cartarch-pg-data:/var/lib/postgresql/data \
  docker.io/library/postgres:${PG_MAJOR}

echo "Waiting for readiness..."
until podman exec cartarch-pg pg_isready -U cartarch >/dev/null 2>&1; do sleep 1; done

# Read-only role NOW, mirroring what cartarch-mcp run_query gets post-v4.
# Validating the migration against this role early surfaces grant gaps
# before they become a cluster debugging session.
podman exec -i cartarch-pg psql -U cartarch -d cartarch << 'SQL'
CREATE ROLE cartarch_ro LOGIN PASSWORD 'throwaway-ro-local-only';
GRANT pg_read_all_data TO cartarch_ro;
SQL

echo
echo "Up. Connection strings:"
echo "  app/migrations: postgresql://cartarch:throwaway-local-only@127.0.0.1:5432/cartarch"
echo "  read-only (future MCP role): postgresql://cartarch_ro:throwaway-ro-local-only@127.0.0.1:5432/cartarch"
echo "Bound to 127.0.0.1 only — nothing exposed off the rig."
