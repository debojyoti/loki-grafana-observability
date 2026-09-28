# Deploy Centralized Production Logging on a DigitalOcean Droplet

This runbook deploys this repository as a production, single-Droplet logging
platform:

```text
Applications -> HTTPS -> Caddy -> Grafana Alloy -> Loki -> DigitalOcean Spaces
                                  Grafana -------^
```

Caddy is the only service with published host ports. Loki, Alloy, and Grafana
remain on the private Docker network. Historical Loki chunks and indexes are
stored in DigitalOcean Spaces; the Droplet keeps only working state, caches,
WAL data, Grafana state, and Caddy certificate state.

Follow the sections in order. Commands marked **local computer** run on your
workstation. Commands marked **Droplet** run over SSH on the server.

## 1. Record the deployment values

Choose these values before creating resources:

| Placeholder | Example | Meaning |
| --- | --- | --- |
| `DROPLET_REGION` | `blr1` | DigitalOcean datacenter region |
| `DROPLET_IP` | `203.0.113.10` | Droplet or assigned Reserved IP |
| `ADMIN_IP` | `198.51.100.25` | Administrator's public IP for restricted SSH |
| `BASE_DOMAIN` | `example.com` | Domain you control |
| `LOGS_DOMAIN` | `logs.example.com` | Public authenticated ingestion endpoint |
| `GRAFANA_DOMAIN` | `grafana.example.com` | Public Grafana endpoint |
| `SPACES_BUCKET` | `production-loki` | Globally unique private Space name |
| `SPACES_ENDPOINT` | `blr1.digitaloceanspaces.com` | Spaces regional endpoint, without `https://` |
| `REPOSITORY_URL` | `git@github.com:company/production-logging.git` | Git repository clone URL |

Use the same region for the Droplet and Space when possible. This reduces
latency and avoids unnecessary cross-region traffic.

Recommended initial Droplet capacity:

```text
Ubuntu 24.04 LTS
2 vCPU
4 GB RAM preferred; 2 GB is the practical minimum
20-50 GB or more local SSD
```

The configured container limits total roughly 1.6 GB by default, leaving host
memory for Ubuntu, Docker, SSH, and filesystem cache. Use a 4 GB Droplet if the
budget permits; resize after measuring actual ingestion and query load.

## 2. Create the private DigitalOcean Space

In the DigitalOcean Control Panel:

1. Open **Spaces Object Storage**.
2. Click **Create Bucket**.
3. Select the same region as the Droplet, for example `blr1`.
4. Select **Standard Storage**. Loki is an active workload, not an archival
   backup client.
5. Leave the CDN disabled.
6. Enter a globally unique bucket name, such as `production-loki`.
7. Select the DigitalOcean project that will contain the logging stack.
8. Create the bucket.
9. Open the bucket settings and confirm:
   - the bucket is private;
   - file listing is restricted;
   - CDN is disabled;
   - no lifecycle expiration rule exists.
10. Record the regional endpoint shown by DigitalOcean. It should resemble
    `blr1.digitaloceanspaces.com`.

Do not make the bucket public. Do not create a blanket lifecycle rule. Loki's
Compactor manages retention using its index; deleting objects independently can
leave dangling index references or remove state Loki still needs.

Official reference: [DigitalOcean Spaces quickstart](https://docs.digitalocean.com/products/spaces/getting-started/quickstart/).

## 3. Create the dedicated Spaces access key

In the DigitalOcean Control Panel:

1. Open **Spaces Object Storage -> Access Keys**.
2. Click **Create Access Key**.
3. Choose **Limited access**.
4. Select only the Loki Space created above.
5. Grant **Read/Write/Delete** permission. Delete is required for
   Compactor-managed retention.
6. Name the key clearly, for example `production-loki`.
7. Create the key.
8. Copy the access key and secret immediately. The secret is displayed only
   once.
9. Store both values in a password manager until they are placed in the
   Droplet's protected `.env` file.

Do not use a personal developer key, a full-access account key, or credentials
shared with another application.

Official reference: [Manage access to DigitalOcean Spaces](https://docs.digitalocean.com/products/spaces/how-to/manage-access/).

## 4. Prepare SSH authentication

Skip key generation if you already have a protected SSH key registered with
DigitalOcean.

On your **local computer**:

```bash
ssh-keygen -t ed25519 -a 100 -C "production-logging-droplet"
```

Accept the default path or choose a dedicated filename, and protect the private
key with a strong passphrase. Add the `.pub` file under **DigitalOcean Control
Panel -> Settings -> Security -> SSH Keys**.

Never copy the private key to the Droplet or into this repository.

## 5. Create the Droplet

In the DigitalOcean Control Panel:

1. Click **Create -> Droplets**.
2. Choose the same region used for the Space.
3. Choose **Ubuntu 24.04 LTS**, 64-bit.
4. Select a plan with at least 2 vCPU and 2 GB RAM; 4 GB RAM is recommended.
5. Select the SSH key from the previous section. Do not use password-only SSH.
6. Enable **Improved Metrics and Monitoring**.
7. Enable automated Droplet backups if the additional cost is acceptable.
   These protect host state but do not replace application-level backups or
   Spaces durability.
8. Use a clear hostname, such as `production-logging-01`.
9. Add a tag such as `central-logging`; the tag can be used to attach a Cloud
   Firewall.
10. Create the Droplet and record its public IPv4 address.

Official references:

- [Create a Droplet](https://docs.digitalocean.com/products/droplets/how-to/create/)
- [DigitalOcean Droplet backups](https://docs.digitalocean.com/products/backups/getting-started/quickstart/)

### Optional: assign a Reserved IP

A Reserved IP makes later Droplet replacement easier because the address can be
reassigned to another Droplet in the same datacenter. If you use one, create it
under **Networking -> Reserved IPs**, assign it to this Droplet, and use that
address for `DROPLET_IP` and DNS.

This is optional for the initial deployment. An assigned Reserved IPv4 is free;
unassigned Reserved IPv4 addresses are billed.

Official reference: [Reserved IP quickstart](https://docs.digitalocean.com/products/networking/reserved-ips/getting-started/quickstart/).

## 6. Create the DigitalOcean Cloud Firewall

Create a Cloud Firewall and apply it to the `central-logging` tag or directly to
the Droplet.

Inbound rules:

| Protocol | Port | Source | Purpose |
| --- | ---: | --- | --- |
| TCP | `22` | `ADMIN_IP/32` | SSH administration |
| TCP | `80` | All IPv4 and IPv6 | ACME HTTP challenge and HTTPS redirect |
| TCP | `443` | All IPv4 and IPv6 | HTTPS ingestion and Grafana |
| UDP | `443` | All IPv4 and IPv6 | Optional HTTP/3; TCP 443 is sufficient |

If the administrator uses IPv6, add the corresponding `/128` source for SSH.
If the administrator's IP is dynamic, temporarily use the narrowest safe
source and update it as soon as possible. Do not expose SSH broadly longer than
necessary.

Outbound rules:

```text
Allow all outbound traffic initially.
```

Outbound access is required for DNS, Ubuntu/Docker package repositories, NTP,
ACME certificate issuance, Git, and the Spaces HTTPS endpoint. Restrict it only
after capturing and testing every required destination.

Do not create inbound rules for ports `3000`, `3100`, `9999`, or `2019`.

Official reference: [DigitalOcean Cloud Firewalls](https://docs.digitalocean.com/products/networking/firewalls/getting-started/quickstart/).

## 7. Point DNS at the Droplet

At the authoritative DNS provider for `BASE_DOMAIN`, create:

```text
Type  Name      Value       TTL
A     logs      DROPLET_IP  300
A     grafana   DROPLET_IP  300
```

Create `AAAA` records only if IPv6 is enabled on the Droplet and both the host
and Cloud Firewall have been tested over IPv6. A broken `AAAA` record can cause
intermittent certificate and browser failures.

Do not enable an HTTP proxy or CDN in front of these names during the first
deployment. If the domain has CAA records, confirm they allow the certificate
authority used by Caddy; otherwise certificate issuance can fail.

From your **local computer**, wait until public resolvers return the expected
address:

```bash
dig +short A logs.example.com @1.1.1.1
dig +short A grafana.example.com @1.1.1.1
```

Replace the example names. Both commands must return `DROPLET_IP` before the
first production start.

Official reference: [Manage DigitalOcean DNS records](https://docs.digitalocean.com/products/networking/dns/how-to/manage-records/).

## 8. Connect and create the deployment user

From your **local computer**:

```bash
ssh root@DROPLET_IP
```

On the **Droplet**, update the base system:

```bash
apt update
apt full-upgrade -y
apt install -y git curl ca-certificates jq unzip ufw unattended-upgrades
timedatectl status
```

The system clock must be synchronized. Spaces Signature V4 requests and TLS
validation depend on accurate time. If `System clock synchronized` is not
`yes`, fix NTP before continuing.

Create an unprivileged deployment operator:

```bash
adduser deploy
usermod -aG sudo deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
```

Keep the current root session open. From a second **local computer** terminal,
test the new account:

```bash
ssh deploy@DROPLET_IP
sudo -v
```

Only after this succeeds, harden SSH from the root session:

```bash
cat >/etc/ssh/sshd_config.d/99-production-logging-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

sshd -t
systemctl reload ssh
```

Open one more new SSH session as `deploy` before closing the original root
session. This prevents an unnoticed SSH configuration mistake from locking you
out.

All remaining Droplet commands should run as `deploy` unless prefixed with
`sudo`.

## 9. Configure the host firewall

The DigitalOcean Cloud Firewall is the primary network boundary. UFW adds a
host-level boundary. While logged in as `deploy`, replace `ADMIN_IP` before
running these commands:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from ADMIN_IP to any port 22 proto tcp comment 'SSH administration'
sudo ufw allow 80/tcp comment 'Caddy HTTP and ACME'
sudo ufw allow 443/tcp comment 'Caddy HTTPS'
sudo ufw allow 443/udp comment 'Caddy HTTP3 optional'
sudo ufw --force enable
sudo ufw status verbose
```

Keep the active SSH session open and confirm a new SSH session still works.
The Docker Compose file publishes only ports 80 and 443; internal service ports
have no host mappings. This is important because Docker manages its own
iptables rules.

## 10. Install Docker Engine and Compose

These commands follow Docker's official Ubuntu repository installation. Run
them on the **Droplet**:

```bash
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc || true
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

Allow the `deploy` user to operate Docker:

```bash
sudo usermod -aG docker deploy
```

The Docker group is root-equivalent. Add only trusted operators. Log out of the
Droplet and reconnect so the new group membership takes effect:

```bash
exit
ssh deploy@DROPLET_IP
docker version
docker compose version
```

Official reference: [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/).

## 11. Configure bounded Docker container logs

The logging platform must remain diagnosable through Docker logs without
allowing Docker's own log files to fill the Droplet disk.

On a fresh **Droplet**, create `/etc/docker/daemon.json`:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
EOF

sudo dockerd --validate --config-file=/etc/docker/daemon.json
sudo systemctl restart docker
docker info --format '{{.LoggingDriver}}'
```

The final command should print `local`. If `/etc/docker/daemon.json` already
exists, merge these keys into the existing JSON instead of overwriting other
settings. Configure this before starting the stack; changing the default log
driver does not change existing containers until they are recreated.

Official reference: [Docker local file logging driver](https://docs.docker.com/engine/logging/drivers/local/).

## 12. Install AWS CLI for the Spaces durability check

The runtime stack does not need AWS CLI. The repository's
`scripts/verify-spaces.sh` acceptance test does.

On the **Droplet**:

```bash
case "$(uname -m)" in
  x86_64) AWSCLI_ARCH=x86_64 ;;
  aarch64|arm64) AWSCLI_ARCH=aarch64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli-install
sudo /tmp/awscli-install/aws/install
aws --version
```

Do not configure a global AWS profile with the Spaces secret. The verification
script reads the protected project `.env` only for the duration of its command.

## 13. Clone the repository

Create a dedicated directory on the **Droplet**:

```bash
sudo install -d -m 700 -o deploy -g deploy /opt/production-logging
git clone REPOSITORY_URL /opt/production-logging
cd /opt/production-logging
git status --short --branch
```

For a private repository, use a read-only deploy key or a trusted operator's
SSH access. Do not store Git access tokens in the repository or `.env`.

Confirm the expected files exist:

```bash
test -f docker-compose.yml
test -f loki/loki-config.yml
test -f alloy/config.alloy
test -f caddy/Caddyfile
test -x scripts/deploy.sh
```

## 14. Create production secrets and `.env`

Create strong values locally on the **Droplet** without printing them into shell
history as command arguments:

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

Use the outputs respectively as:

1. `GRAFANA_ADMIN_PASSWORD`
2. `GRAFANA_SECRET_KEY`
3. `LOG_INGEST_PASSWORD`

Copy the template and restrict it before editing:

```bash
cd /opt/production-logging
cp .env.example .env
chmod 600 .env
nano .env
```

Fill every placeholder. A production example, with secrets intentionally
omitted, is:

```dotenv
COMPOSE_PROJECT_NAME=production-logging

LOGS_DOMAIN=logs.example.com
GRAFANA_DOMAIN=grafana.example.com

GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD='<generated password>'
GRAFANA_SECRET_KEY='<generated 64-character key>'

DO_SPACES_REGION=blr1
DO_SPACES_ENDPOINT=blr1.digitaloceanspaces.com
DO_SPACES_BUCKET=production-loki
DO_SPACES_ACCESS_KEY='<dedicated access key>'
DO_SPACES_SECRET_KEY='<dedicated secret key>'

LOG_INGEST_USERNAME=logger
LOG_INGEST_PASSWORD='<generated password>'
LOG_INGEST_PASSWORD_HASH='replace-with-caddy-bcrypt-hash'

LOKI_RETENTION_PERIOD=720h
MAX_INGEST_BODY_SIZE=1MB

LOKI_MEMORY_LIMIT=896m
GRAFANA_MEMORY_LIMIT=384m
ALLOY_MEMORY_LIMIT=256m
CADDY_MEMORY_LIMIT=128m
```

Important rules:

- Keep `DO_SPACES_ENDPOINT` free of `https://` and bucket names.
- Use the endpoint for the bucket's actual region.
- Leave `LOG_INGEST_PASSWORD_HASH` as the template placeholder on the first
  run. `scripts/deploy.sh` generates the Caddy bcrypt hash and writes it back to
  `.env` in single quotes.
- Single-quote values containing `$`, spaces, `#`, or shell metacharacters.
- Keep `.env` mode `600`.
- Keep the same `GRAFANA_SECRET_KEY` across upgrades and moves; changing it can
  invalidate secrets stored by Grafana.

Verify that Git ignores the secret file:

```bash
chmod 600 .env
git check-ignore -v .env
git ls-files --error-unmatch .env >/dev/null 2>&1 && echo 'ERROR: .env is tracked' || echo '.env is untracked'
```

The final command must report `.env is untracked`.

## 15. Run preflight checks

On the **Droplet**:

```bash
cd /opt/production-logging

getent ahostsv4 logs.example.com
getent ahostsv4 grafana.example.com

sudo ss -lntup | grep -E ':(80|443)\b' || true

docker compose --env-file .env config --quiet
git status --short
```

Confirm:

- both names resolve to `DROPLET_IP`;
- nothing else is listening on ports 80 or 443;
- Compose validation prints no error;
- only expected local files are modified;
- `.env` does not appear in `git status`.

Do not continue while DNS points elsewhere. Caddy obtains public certificates
at startup and needs inbound TCP ports 80 and 443.

## 16. Deploy the stack

On the **Droplet**:

```bash
cd /opt/production-logging
./scripts/deploy.sh
```

The deployment script:

1. verifies required `.env` values;
2. enforces `.env` mode `600`;
3. generates the Caddy-compatible ingestion password hash when necessary;
4. performs a fast-forward-only `git pull` when an upstream exists;
5. pulls the pinned images;
6. validates Compose;
7. starts the services and waits for their health checks;
8. prints service status.

Expected services:

```text
caddy     healthy
alloy     healthy
loki      healthy
grafana   healthy
```

Inspect the startup logs:

```bash
docker compose ps
docker compose logs --tail=200 loki
docker compose logs --tail=200 alloy
docker compose logs --tail=200 grafana
docker compose logs --tail=200 caddy
```

For certificate problems, focus on Caddy's log. Common causes are incorrect
DNS, blocked ports 80/443, a restrictive CAA record, another process using the
ports, or ACME rate limiting after repeated failed attempts.

## 17. Validate HTTPS and authentication

From your **local computer**:

```bash
curl -I https://grafana.example.com
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Content-Type: application/json' \
  --data '{"streams":[]}' \
  https://logs.example.com/loki/api/v1/push
```

The Grafana request should complete with a valid public certificate. The
unauthenticated ingestion request must return `401`.

On the **Droplet**, run the repository health checks:

```bash
cd /opt/production-logging
./scripts/healthcheck.sh
```

The script checks internal readiness, public Grafana health, unauthenticated
ingestion, and the absence of published ports for Loki, Alloy, and Grafana.

Open `https://grafana.example.com` and sign in with
`GRAFANA_ADMIN_USER`/`GRAFANA_ADMIN_PASSWORD`. Confirm:

- anonymous browsing redirects to login;
- the default datasource is **Loki**;
- **Dashboards -> Logging -> Production Logs Overview** exists;
- **Explore** can select the Loki datasource.

## 18. Run the multi-project ingestion test

On the **Droplet**:

```bash
cd /opt/production-logging
./scripts/send-test-log.sh
```

The script sends five streams through the public, authenticated Caddy endpoint:

```text
internal / logging-test / api / production
client-a / project-a / api / production
client-a / project-a / worker / production
client-b / project-b / api / production
client-b / project-b / api / staging
```

In Grafana Explore, run each query and confirm only the expected stream appears:

```logql
{client="client-a"}
{client="client-b"}
{client="client-a", service="worker"}
{environment="staging"}
```

Also confirm the JSON field query works:

```logql
{client="client-b", project="project-b"} | json | level="error"
```

## 19. Prove data is written to Spaces

Seeing data in Grafana is not enough. Recent data may still be in Loki's memory,
WAL, or active local chunk.

Perform a graceful Loki restart to flush active data, then inspect Spaces:

```bash
cd /opt/production-logging
docker compose restart loki
docker compose up -d --wait
./scripts/verify-spaces.sh
```

If the verification script reports no objects immediately, wait a few minutes
and retry. Do not change Loki to filesystem storage and do not create a bucket
lifecycle rule as a workaround.

After objects are present:

1. query all test streams again in Grafana;
2. restart Loki one more time;
3. query the historical streams again;
4. inspect Loki logs for S3 authentication, endpoint, signature, or permission
   errors.

This proves that the configured Space is being used and that Loki can read its
historical objects after restart.

## 20. Verify external network isolation

Run these checks from a machine that is **not** the Droplet:

```bash
nc -vz DROPLET_IP 3000
nc -vz DROPLET_IP 3100
nc -vz DROPLET_IP 9999
nc -vz DROPLET_IP 2019
```

All four connections must fail or time out. Only these public endpoints should
work:

```text
http://logs.example.com       -> HTTPS redirect/authenticated push route
https://logs.example.com      -> authenticated push route only
http://grafana.example.com    -> HTTPS redirect
https://grafana.example.com   -> Grafana login
```

Also check the actual Docker mappings on the **Droplet**:

```bash
docker compose ps
sudo ss -lntup
```

Only Caddy should bind host ports 80 and 443. `3000/tcp`, `3100/tcp`, and
`9999/tcp` may appear as container-internal ports in `docker compose ps`, but
must not have a host address such as `0.0.0.0:` or `[::]:` before them.

## 21. Prove recovery after a Droplet reboot

Schedule a short maintenance window. Before rebooting, confirm test logs are
queryable. Then on the **Droplet**:

```bash
sudo reboot
```

Wait for SSH to return, reconnect, and run:

```bash
cd /opt/production-logging
docker compose ps
./scripts/healthcheck.sh
```

All services should return automatically because they use
`restart: unless-stopped`. Query the pre-reboot test logs again and rerun:

```bash
./scripts/verify-spaces.sh
```

Do not declare the production deployment complete until historical queries work
after this host reboot.

## 22. Create the first backup

On the **Droplet**:

```bash
cd /opt/production-logging
./scripts/backup.sh
ls -lh backups/
```

The backup script briefly stops Grafana to get a consistent SQLite database,
archives Grafana and Caddy state, archives repository configuration without
`.env`, restarts Grafana, and waits for Grafana to become healthy.

Important:

- The state archive contains Caddy certificate material. Treat it as sensitive.
- `.env` is intentionally excluded. Back it up separately in a secrets manager.
- Copy backup archives to an encrypted, access-controlled off-Droplet location.
- A backup stored only on the same Droplet is not a disaster-recovery backup.
- Loki's historical object data is already in Spaces and is not copied from the
  Droplet.
- Periodically perform a restore rehearsal on a different Droplet.

DigitalOcean Droplet backups are useful host-level protection, but they do not
replace Git, protected `.env` storage, application-state archives, or Spaces.

## 23. Configure DigitalOcean resource alerts

With Improved Metrics enabled, create alerts for:

```text
CPU sustained above 80%
Memory sustained above 80-85%
Disk usage above 75% warning and 85% critical
Disk I/O saturation if available
Droplet offline/unreachable
```

Alert thresholds should notify an operator before the host reaches an OOM or
disk-full condition. Historical logs are in Spaces, but Loki WAL/cache,
Grafana's database, Docker logs, and system logs still use local disk.

Official reference: [DigitalOcean Monitoring](https://docs.digitalocean.com/products/monitoring/how-to/).

## 24. Routine deployments and upgrades

Before every upgrade:

```bash
cd /opt/production-logging
./scripts/backup.sh
git status --short
git fetch --prune
git log --oneline --decorate HEAD..@{upstream}
```

Review the incoming changes and upstream release notes. Then deploy:

```bash
./scripts/deploy.sh
./scripts/healthcheck.sh
./scripts/send-test-log.sh
./scripts/verify-spaces.sh
```

The normal deployment must never use:

```text
docker compose down -v
docker volume rm ...
git reset --hard
```

Do not change an existing Loki schema period after it has received data. A
future schema migration needs a new `schema_config.configs` entry dated in the
future, followed by a controlled rollout.

### Rollback

If a new image or configuration fails:

1. preserve logs with `docker compose logs`;
2. restore the previous known-good Git revision using a normal revert or
   deployment of the prior release tag;
3. keep `.env` and every named volume intact;
4. run `docker compose config --quiet`;
5. run `docker compose up -d --wait`;
6. repeat health, ingestion, Spaces, and historical-query tests.

Never roll back by deleting volumes.

## 25. Credential rotation

### Spaces credentials

1. Create a second limited Read/Write/Delete key for the same bucket.
2. Update `DO_SPACES_ACCESS_KEY` and `DO_SPACES_SECRET_KEY` in `.env`.
3. Run `./scripts/deploy.sh`.
4. Send a test log and run `./scripts/verify-spaces.sh`.
5. Confirm historical queries.
6. Revoke the old key only after validation succeeds.

Regenerating the old key's secret invalidates it immediately, so overlapping
with a second key is safer.

### Ingestion credentials

The initial stack has one global Basic Auth credential, so coordinate rotation
with every sending application:

1. choose a maintenance window;
2. set a new `LOG_INGEST_PASSWORD` in `.env`;
3. reset `LOG_INGEST_PASSWORD_HASH` to
   `'replace-with-caddy-bcrypt-hash'`;
4. run `./scripts/deploy.sh` to generate and load the new hash;
5. update every application secret immediately;
6. run `./scripts/send-test-log.sh` and application-specific tests.

Per-project tokens are a future improvement because they allow independent
rotation and revocation.

### Grafana credentials

`GRAFANA_ADMIN_PASSWORD` initializes a new Grafana database. After the first
start, change user passwords through Grafana's user-management workflow or its
documented administrative tooling. Changing only `.env` does not reset an
existing Grafana user password.

## 26. Troubleshooting sequence

Always troubleshoot from the outside inward:

1. **DNS**

   ```bash
   dig +short A logs.example.com
   dig +short A grafana.example.com
   ```

2. **Cloud Firewall and UFW**

   ```bash
   sudo ufw status verbose
   sudo ss -lntup
   ```

3. **Compose state**

   ```bash
   docker compose ps
   ```

4. **Caddy and certificates**

   ```bash
   docker compose logs --tail=200 caddy
   ```

5. **Grafana**

   ```bash
   docker compose logs --tail=200 grafana
   docker compose exec -T caddy wget -qO- http://grafana:3000/api/health
   ```

6. **Alloy**

   ```bash
   docker compose logs --tail=200 alloy
   docker compose exec -T caddy wget -qO- http://alloy:9999/ready
   ```

7. **Loki and Spaces**

   ```bash
   docker compose logs --tail=200 loki
   docker compose exec -T caddy wget -qO- http://loki:3100/ready
   ./scripts/verify-spaces.sh
   ```

Do not send the platform's only copy of its own diagnostics back into itself.
Docker and system logs remain the primary recovery path.

## 27. Production completion checklist

Record evidence for every item:

- [ ] Private Standard Storage Space exists with CDN disabled.
- [ ] Loki has a bucket-limited Read/Write/Delete Spaces key.
- [ ] Droplet uses Ubuntu, SSH keys, a non-root operator, and synchronized time.
- [ ] Cloud Firewall and UFW expose only SSH, HTTP, HTTPS, and optional HTTP/3.
- [ ] Docker Engine, Compose, and bounded local Docker logs are configured.
- [ ] `.env` is mode `600`, ignored by Git, and backed up separately.
- [ ] `docker compose config --quiet` succeeds.
- [ ] Loki, Alloy, Grafana, and Caddy are healthy.
- [ ] Public TLS certificates are valid.
- [ ] Unauthenticated ingestion returns HTTP 401.
- [ ] Grafana requires login.
- [ ] Loki datasource and dashboard are provisioned automatically.
- [ ] All five acceptance streams are queryable.
- [ ] Client, service, and environment selectors isolate streams correctly.
- [ ] Loki objects are visible in the private Space.
- [ ] Historical logs survive a Loki restart.
- [ ] Historical logs survive a full Droplet reboot.
- [ ] Ports 3000, 3100, 9999, and 2019 are unreachable externally.
- [ ] A protected off-Droplet backup exists.
- [ ] CPU, memory, disk, and availability alerts are configured.
- [ ] One real production Node.js service has completed an ingestion test.

Only after every applicable check passes should the deployment be considered
production-complete.
