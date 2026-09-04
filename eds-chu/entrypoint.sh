#!/bin/sh
set -eu

SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"
{
    echo "PATH=/usr/local/bin:/usr/bin:/bin"
    printf '%s /usr/local/bin/python -m pipeline.run\n' "$SCHEDULE"
} > /tmp/eds-crontab

echo "Cron pipeline : ${SCHEDULE} (TZ=${TZ:-UTC})"

python - <<'PY'
import os, sys, time
import clickhouse_connect

host = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
try:
    port = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
except ValueError:
    print(
        f"CLICKHOUSE_PORT invalide : {os.environ.get('CLICKHOUSE_PORT')!r}",
        file=sys.stderr,
    )
    sys.exit(1)
user = os.environ.get("CLICKHOUSE_USER", "default")
password = os.environ.get("CLICKHOUSE_PASSWORD", "")

for attempt in range(1, 31):
    try:
        clickhouse_connect.get_client(
            host=host, port=port, username=user, password=password
        ).query("SELECT 1")
        print("ClickHouse est prêt.")
        sys.exit(0)
    except Exception as exc:
        print(f"En attente de ClickHouse ({attempt}/30) : {exc}")
        time.sleep(2)

print("ClickHouse injoignable après 60 s.", file=sys.stderr)
sys.exit(1)
PY

if [ "${RUN_ON_START:-1}" = "1" ]; then
    if ! python -m pipeline.run; then
        echo "Run de démarrage en échec, le cron reprendra au prochain tick." >&2
    fi
fi

if ! /usr/local/bin/supercronic -test /tmp/eds-crontab >/dev/null; then
    echo "CRON_SCHEDULE invalide : ${SCHEDULE}" >&2
    exit 1
fi

exec /usr/local/bin/supercronic /tmp/eds-crontab
