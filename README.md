# Centralized Production Logging

A small, single-Droplet logging platform for multiple projects. Caddy is the
only public service. It terminates HTTPS, authenticates log ingestion, and
routes logs to Grafana Alloy. Alloy applies a low-cardinality label allowlist
and batches logs into Loki. Loki stores TSDB v13 chunks and indexes in a private
DigitalOcean Space. Grafana provides Explore and a provisioned overview
dashboard.

The production configuration does **not** use the Droplet filesystem as the
historical log store. The `loki-data` volume contains only the WAL, active
indexes, cache, and Compactor working data.

## Architecture

```text
Node APIs / workers / cron services
              |
              | HTTPS + Basic Auth
              v
       logs.example.com:443
              |
            Caddy  <---------------- grafana.example.com:443
              |                              |
              v                              v
        Grafana Alloy                     Grafana
              |                              |
              +-------------> Loki <---------+
                                |
                         S3-compatible API
                                |
                                v
                   private DigitalOcean Space

Published host ports: 80, 443
Unpublished ports: Alloy 9999, Loki 3100, Grafana 3000
```

All four containers share one private Compose bridge network. The network is
not marked `internal: true`, because Loki needs outbound HTTPS access to Spaces
and Caddy needs outbound access to ACME certificate authorities. No internal
service port is published on the host.

## Pinned versions

| Component | Version |
| --- | --- |
| Grafana Loki | `3.7.2` |
| Grafana Alloy | `1.19.2` |
| Grafana | `13.2.1` |
| Caddy | `2.11.3-alpine` |

The Loki configuration follows the current TSDB v13, S3, and Compactor
retention documentation. Alloy uses the stable Push API, relabel, batching, and
retry features. Alloy's experimental disk WAL/custom queue controls are
intentionally not enabled.

Relevant upstream references:

- [Loki storage](https://grafana.com/docs/loki/latest/configure/storage/)
- [Loki retention](https://grafana.com/docs/loki/latest/operations/storage/retention/)
- [Alloy `loki.source.api`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.api/)
- [Alloy `loki.write`](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/)
- [DigitalOcean Spaces API](https://docs.digitalocean.com/reference/api/spaces/)
- [Caddy Basic Auth](https://caddyserver.com/docs/caddyfile/directives/basic_auth)

## Requirements

- Ubuntu Droplet, preferably 2 vCPU and 2–4 GB RAM
- Docker Engine with Docker Compose v2
- A private DigitalOcean Space with CDN disabled
- A dedicated Spaces access key and secret
- Two DNS records pointing to the Droplet
- TCP 80 and 443 reachable from the Internet
- SSH access, preferably restricted to trusted source addresses

Install Docker using Docker's current
[Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/), then
verify the host:

```bash
docker version
docker compose version
```

Do not place the repository or Docker data directory on ephemeral storage.

## DigitalOcean Spaces

Create one private Space, for example:

```text
Region:   blr1
Bucket:   production-loki
Endpoint: blr1.digitaloceanspaces.com
CDN:      disabled
ACL:      private
```

Create a dedicated Spaces key for Loki. Do not reuse a developer key or a key
owned by another application. Spaces uses its regional S3-compatible endpoint
and AWS Signature V4. Do not add a bucket lifecycle rule initially; Loki's
Compactor owns retention.

## DNS and firewall

Create these records before the first production start:

```text
logs.example.com      A/AAAA -> Droplet IP
grafana.example.com   A/AAAA -> Droplet IP
```

An example UFW policy is:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from YOUR_ADMIN_IP to any port 22 proto tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Replace `YOUR_ADMIN_IP` before running the commands. Also apply an equivalent
DigitalOcean Cloud Firewall. Never add rules for ports 3000, 3100, or 9999.

## Production configuration

Clone the repository and create the untracked environment file:

```bash
git clone YOUR_REPOSITORY_URL production-logging
cd production-logging
cp .env.example .env
chmod 600 .env
```

Edit `.env`, replacing every placeholder. Values containing shell
metacharacters should be single-quoted. `scripts/deploy.sh` generates and
stores the Caddy-compatible bcrypt hash from `LOG_INGEST_PASSWORD`; do not hash
it manually unless desired.

| Variable | Purpose |
| --- | --- |
| `COMPOSE_PROJECT_NAME` | Stable prefix for containers, volumes, and network |
| `LOGS_DOMAIN` | Public authenticated Push API hostname |
| `GRAFANA_DOMAIN` | Public Grafana hostname |
| `GRAFANA_ADMIN_USER` | Initial Grafana administrator name |
| `GRAFANA_ADMIN_PASSWORD` | Initial administrator password |
| `GRAFANA_SECRET_KEY` | Stable 32+ character key protecting Grafana secrets |
| `DO_SPACES_REGION` | Spaces region slug, such as `blr1` |
| `DO_SPACES_ENDPOINT` | Regional endpoint without a scheme |
| `DO_SPACES_BUCKET` | Private Space name |
| `DO_SPACES_ACCESS_KEY` | Dedicated Spaces key ID |
| `DO_SPACES_SECRET_KEY` | Dedicated Spaces secret |
| `LOG_INGEST_USERNAME` | Basic Auth ingestion username |
| `LOG_INGEST_PASSWORD` | Basic Auth password used by sending applications/tests |
| `LOG_INGEST_PASSWORD_HASH` | Generated bcrypt value consumed by Caddy |
| `LOKI_RETENTION_PERIOD` | Loki/Compactor retention, initially `720h` |
| `MAX_INGEST_BODY_SIZE` | Maximum HTTP push request body, initially `1MB` |
| `*_MEMORY_LIMIT` | Per-container memory ceilings |

Generate `GRAFANA_SECRET_KEY` and strong passwords with a trusted password
manager or an OS CSPRNG. The Grafana admin credentials seed a new Grafana
database only; changing the environment variable does not reset an existing
admin password in `grafana-data`.

Validate and deploy:

```bash
./scripts/deploy.sh
```

The script performs a fast-forward-only `git pull` when an upstream exists,
pulls pinned images, validates Compose, starts the stack with health checks, and
prints service status. It never deletes volumes.

Useful operational commands:

```bash
docker compose ps
docker compose logs -f loki
docker compose logs -f alloy
docker compose logs -f grafana
docker compose logs -f caddy
```

## Local milestone-1 test

The local override uses TSDB v13 with filesystem object storage. It is only for
proving `test log -> Caddy -> Alloy -> Loki -> Grafana`; never use it in
production.

Create `.env` from the example, set these values, and choose real local
passwords:

```text
LOGS_DOMAIN=logs.localhost
GRAFANA_DOMAIN=grafana.localhost
GRAFANA_ADMIN_PASSWORD=<local password>
GRAFANA_SECRET_KEY=<at least 32 random characters>
LOG_INGEST_PASSWORD=<local password>
```

Generate the ingestion hash and append it as the last definition in `.env`:

```bash
HASH="$(docker run --rm caddy:2.11.3-alpine caddy hash-password --plaintext 'YOUR_LOCAL_INGEST_PASSWORD')"
printf "\nLOG_INGEST_PASSWORD_HASH='%s'\n" "$HASH" >> .env
chmod 600 .env
```

Then start and test the local stack:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --wait
CURL_INSECURE=1 ./scripts/healthcheck.sh
CURL_INSECURE=1 ./scripts/send-test-log.sh
```

Caddy creates a local CA certificate. `CURL_INSECURE=1` is acceptable only for
this loopback test. Open `https://grafana.localhost` and explicitly trust the
local certificate in the browser if prompted.

Stop the local stack without deleting data:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml down
```

Never add `-v` unless intentionally destroying all local state.

## First production validation

Run the automated checks and submit the five acceptance streams:

```bash
./scripts/healthcheck.sh
./scripts/send-test-log.sh
```

The health check verifies:

- Loki, Alloy, and Grafana internal health endpoints
- public Grafana health
- unauthenticated ingestion returns HTTP 401
- ports 3000, 3100, and 9999 are not published by Compose

The send script creates these streams:

```text
internal / logging-test / api / production
client-a / project-a / api / production
client-a / project-a / worker / production
client-b / project-b / api / production
client-b / project-b / api / staging
```

Open `https://grafana.example.com`, sign in, and use Explore with the provisioned
Loki datasource. Confirm these selectors independently:

```logql
{client="client-a"}
{client="client-b"}
{client="client-a", service="worker"}
{environment="staging"}
```

Also open **Dashboards -> Logging -> Production Logs Overview**. Its variables
cascade through client, project, environment, and service. `level` is parsed
from the JSON line rather than indexed as a Loki label.

### Prove Spaces durability

Seeing a log in Grafana is not proof that it reached Spaces: recent data can
still reside in Loki's WAL or active chunk. After test ingestion, allow the
chunk to flush or perform a graceful Loki restart, then inspect the bucket:

```bash
docker compose restart loki
./scripts/verify-spaces.sh
```

`verify-spaces.sh` requires the AWS CLI and lists objects through the regional
Spaces endpoint. Confirm that object keys and sizes are present, then query the
test logs again in Grafana. This proves both object-store writes and queryability
after a Loki restart.

After a scheduled Droplet reboot, repeat:

```bash
docker compose ps
./scripts/healthcheck.sh
```

and query the same historical test records. The host-reboot check cannot be
substituted with a container restart.

## Adding a project

Every application supplies a stable, normalized label set:

```env
LOG_ENDPOINT=https://logs.example.com/loki/api/v1/push
LOG_USERNAME=logger
LOG_PASSWORD=<secret>
LOG_CLIENT=acme
LOG_PROJECT=payments
LOG_SERVICE=api
LOG_ENVIRONMENT=production
LOG_LEVEL=info
```

Use lowercase, bounded values. The four required stream labels are `client`,
`project`, `service`, and `environment`. `region` and `runtime` are optional.
Alloy drops every other incoming indexed label to limit cardinality.

Never make these indexed labels:

```text
requestId userId email sessionId transactionId ip url timestamp errorMessage
```

Keep them in the structured JSON line. A push request has this shape:

```json
{
  "streams": [
    {
      "stream": {
        "client": "acme",
        "project": "payments",
        "service": "api",
        "environment": "production"
      },
      "values": [
        [
          "<unix-nanoseconds>",
          "{\"level\":\"error\",\"message\":\"Payment failed\",\"requestId\":\"req_123456\"}"
        ]
      ]
    }
  ]
}
```

The application integration must batch asynchronously, set short timeouts, use
bounded queues, retry with backoff, and drop after a bounded failure window.
Logging failure must never fail or delay a business request. Keep application
stdout logging available for DigitalOcean App Platform troubleshooting.

## Node.js logging standard

Use Pino's normal API so a later internal `@company/production-logger` package
can provide transport details without changing call sites:

```javascript
import pino from "pino";

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    client: process.env.LOG_CLIENT,
    project: process.env.LOG_PROJECT,
    service: process.env.LOG_SERVICE,
    environment: process.env.LOG_ENVIRONMENT,
  },
  redact: {
    paths: [
      "password",
      "token",
      "accessToken",
      "refreshToken",
      "authorization",
      "headers.authorization",
      "cookie",
      "headers.cookie",
      "secret",
      "apiKey",
    ],
    censor: "[REDACTED]",
  },
});

logger.info({ requestId, userId, duration }, "Request completed");
logger.error({ err, requestId }, "Request failed");
```

Do not stringify `err` manually; Pino serializes errors. Do not log file bodies,
base64 data, full responses, large arrays, database dumps, credentials, tokens,
cookies, payment-card details, or OTP values. Production defaults to `info`;
enable `debug` only for a bounded diagnostic window.

The first infrastructure milestone intentionally does not ship a custom npm
package. `scripts/send-test-log.sh` is the ingestion contract test. Build the
internal package only when connecting the first real application, and include
tests for queue overflow, timeouts, retries, redaction, and process shutdown.

## Useful LogQL

```logql
{environment="production"}
{client="acme"}
{client="acme", project="payments"}
{client="acme", project="payments", service="api"}
{client="acme", project="payments"} | json | level="error"
{client="acme", project="payments"} |= "req_123456"
{project="payments"} |= "ECONNRESET"
```

## Retention and object lifecycle

Retention defaults to 30 days (`720h`). Loki's singleton Compactor removes old
index references and later deletes chunks from Spaces. TSDB uses the required
24-hour index period. The delete-request store is also in Spaces, while
Compactor working files persist in `loki-data`.

Do not apply a blanket Spaces expiration policy. If a lifecycle safety net is
added later, test Loki retention first, scope the rule only to verified chunk
prefixes, and make its age substantially longer than Loki retention plus the
Compactor deletion delay (for example, 90+ days for 30-day Loki retention).
Never expire the entire bucket by age; indexes and Compactor state have
different lifecycle requirements.

## Backup and restore

Configuration and provisioned dashboards belong in Git. Historical Loki data
is already in Spaces and is deliberately not copied from the Droplet.

Create a consistent state backup:

```bash
./scripts/backup.sh
```

The script briefly stops Grafana, archives `grafana-data` and Caddy's data
(including certificate state), archives repository configuration without
`.env`, restarts Grafana, and writes mode-600 files under `backups/`. Caddy state
contains TLS private material, so store the archive in an encrypted, access-
controlled backup destination. Back up `.env` separately in a secrets manager.

For restore, stop the affected service, extract the corresponding archive into
its Docker volume using a pinned utility image, restore ownership if necessary,
then start the service and run `scripts/healthcheck.sh`. Always test restoration
on a separate host before relying on the backup.

## Upgrades

1. Read release notes for Loki, Alloy, Grafana, and Caddy.
2. Back up state with `scripts/backup.sh`.
3. Change one pinned version at a time.
4. Validate Compose and the actual Loki/Alloy/Caddy configs.
5. Deploy and repeat ingestion, Spaces, restart, and historical-query tests.
6. Roll back the image pin if validation fails; do not delete volumes.

Schema changes require a new `schema_config.configs` entry with a future date.
Never edit the existing TSDB v13 period in place after production data exists.

## Failure tests

Run these during a maintenance window after the baseline passes:

```bash
docker compose restart loki
docker compose restart grafana
docker compose ps
```

Confirm historical queries and the provisioned datasource after each restart.
Also verify:

- wrong ingestion credentials return 401
- blocking Spaces access makes Loki log visible storage errors and become
  unhealthy/not ready rather than silently switching storage
- external scans cannot connect to 3000, 3100, or 9999
- a Droplet reboot returns all services because of `restart: unless-stopped`
- Grafana remains authenticated and anonymous access remains disabled

Do not make the platform depend only on itself for troubleshooting. Its primary
diagnostic source remains `docker compose logs`.

## Troubleshooting

### Loki is not ready

```bash
docker compose logs --tail=200 loki
docker compose exec caddy wget -qO- http://loki:3100/ready
```

Look for invalid configuration, volume permissions, WAL replay, or Spaces
errors. Verify the endpoint has no `https://` prefix in `.env`; Loki's expanded
S3 configuration enables TLS with `insecure: false`.

### Spaces authentication or signature errors

Confirm region, endpoint, bucket, dedicated key pair, host clock, and private
bucket access. The endpoint must match the Space's region. Test the same values:

```bash
./scripts/verify-spaces.sh
```

Do not work around TLS or signature failures with `insecure: true`.

### Alloy cannot reach Loki

```bash
docker compose logs --tail=200 alloy
docker compose exec caddy wget -qO- http://alloy:9999/ready
docker compose exec caddy wget -qO- http://loki:3100/ready
```

Alloy retry/drop counters are exposed on its internal metrics endpoint. The
Alloy UI and metrics port are intentionally not public.

### Grafana cannot reach Loki

```bash
docker compose logs --tail=200 grafana
docker compose exec caddy wget -qO- http://grafana:3000/api/health
docker compose exec caddy wget -qO- http://loki:3100/ready
```

The datasource UID is `loki` and its internal URL is `http://loki:3100`.
Provisioning is read-only and is reapplied on restart.

### Caddy certificate errors

Check that both DNS records resolve publicly to the Droplet, ports 80/443 are
open, no other service binds them, and ACME outbound traffic is allowed:

```bash
docker compose logs --tail=200 caddy
```

Do not put a proxy/CDN in front until direct certificate issuance works.

### Permission problems

Named volumes are initialized for the container images' users. If state was
manually restored, inspect ownership inside the affected volume and correct it
to the image's runtime user. Do not solve permissions by making state
world-writable.

## Production acceptance record

Before declaring a real deployment complete, record evidence for every item:

- all four containers healthy
- valid Loki and Alloy configurations using the pinned images
- public HTTPS certificates valid
- unauthenticated push rejected
- Grafana login required and anonymous access rejected
- datasource/dashboard provisioned automatically
- all five acceptance streams queryable and isolated
- objects present in the private Space
- historical logs queryable after Loki restart
- historical logs queryable after Droplet restart
- ports 3000, 3100, and 9999 unreachable externally
- `.env` mode 600 and absent from Git
- 30-day Compactor retention active

Repository validation alone cannot prove the Spaces write, DNS/TLS issuance,
firewall behavior, or Droplet-reboot persistence. Those checks must be run on
the target DigitalOcean resources.
