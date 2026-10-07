# Node.js → Central Loki logging: implementation handoff

## Goal

Add production-ready structured logging to this Node.js application and send
every application log record to the central Loki platform. Logging must remain
available on `stdout` as well, so platform/container logs are still useful when
the remote logging service is unavailable.

This document deliberately contains no real endpoint hostnames or credentials.
The deployer will supply them as environment variables through the application's
normal secret-management mechanism; do not commit them to the repository.

## Non-negotiable behaviour

- Use **Pino** as the application's single structured logger. Do not send one
  HTTP request per log line.
- Send records to the Loki Push API asynchronously in bounded batches.
- A Loki timeout, authentication failure, rate limit, or outage must **never**
  fail, slow, or change the result of a business request or background job.
- Continue writing the same structured records to `stdout`.
- Replace direct application uses of `console.log`, `console.info`,
  `console.warn`, and `console.error` with the shared logger. Do not monkey
  patch `console`; change application call sites and framework adapters.
- Capture startup/shutdown events, HTTP request failures, job/worker failures,
  and unhandled errors. Ensure errors are passed as `err` objects, not manually
  stringified.
- Redact secrets before records reach either output.

## Runtime configuration

Read the following values only from environment variables. Validate them during
logger initialization, but do not stop application startup merely because the
remote logging configuration is absent or invalid: fall back to stdout-only
logging and emit one clear local warning.

```dotenv
# Required together to enable remote Loki delivery
LOG_ENDPOINT=https://<logs-host>/loki/api/v1/push
LOG_USERNAME=<Basic-Auth-username>
LOG_PASSWORD=<Basic-Auth-password>

# Required, stable stream identity; use lowercase, bounded values.
LOG_CLIENT=<customer-or-organization>
LOG_PROJECT=<application-or-project>
LOG_SERVICE=<api|worker|cron|other-stable-service-name>
LOG_ENVIRONMENT=<production|staging|development>

# Optional low-cardinality labels
LOG_REGION=<stable-region-name>
LOG_RUNTIME=<node-version-or-stable-runtime-name>

# Application logging level; use info in production by default.
LOG_LEVEL=info
```

`LOG_ENDPOINT` must be the full HTTPS URL ending in
`/loki/api/v1/push`. Do not point an application at an internal Loki, Grafana,
or Alloy address. The public ingestion endpoint performs TLS and Basic Auth.

Keep the username and password in a secret store. They are not application
configuration, must not appear in source, tests, fixtures, screenshots, or
logs, and must not be injected into frontend/browser code.

## Stream-label contract

Each Loki stream must include these four labels:

| Label | Source | Rule |
| --- | --- | --- |
| `client` | `LOG_CLIENT` | Required; stable, lowercase, bounded cardinality. |
| `project` | `LOG_PROJECT` | Required; stable, lowercase, bounded cardinality. |
| `service` | `LOG_SERVICE` | Required; stable service name such as `api` or `worker`. |
| `environment` | `LOG_ENVIRONMENT` | Required; for example `production` or `staging`. |
| `region` | `LOG_REGION` | Optional; only a stable deployment region. |
| `runtime` | `LOG_RUNTIME` | Optional; only a stable runtime identifier. |

The platform discards any other Loki labels. In particular, **never** use these
as labels: request IDs, trace IDs, user IDs, emails, session IDs, transaction
IDs, IP addresses, URLs, timestamps, error messages, or dynamic resource IDs.
Put those values inside the JSON log record instead.

Do not put `level` in Loki stream labels. It is a JSON field and is queried in
Grafana with `| json | level="error"`.

## Required implementation design

Create one shared logger module (for example `src/observability/logger.ts` or
the repository-equivalent). It should be the only place that knows about Loki
transport details.

### 1. Produce JSON with Pino

Install and use `pino` with the repository's existing package manager. Configure:

- `level: process.env.LOG_LEVEL ?? "info"`.
- A static Pino `base` object containing `client`, `project`, `service`, and
  `environment` for local readability. These are also used separately as the
  Loki stream labels.
- Standard Pino error serialization. Call it as
  `logger.error({ err, requestId }, "Request failed")`; do **not** call
  `logger.error(err.stack)` or pre-serialize the error.
- A redact policy that covers, at minimum:

  ```text
  password, token, accessToken, refreshToken, authorization,
  headers.authorization, cookie, headers.cookie, secret, apiKey,
  clientSecret, privateKey, credentials
  ```

  Use a consistent censor value such as `[REDACTED]`.
- JSON output to `stdout` in every environment. Do not use pretty-printing in
  production, because the remote payload needs valid JSON records.

Use child loggers for contextual fields that belong to many messages in one
operation, for example `logger.child({ requestId, route })`. Contextual fields
stay in JSON; they do not become Loki labels.

### 2. Mirror Pino records to a custom asynchronous Loki stream

Use Pino's supported multi-stream/transport mechanism (or a Pino-compatible
`Writable`) to write every JSON record both to `process.stdout` and a custom
Loki batcher. Do not rely on scraping stdout from another container.

The Loki batcher must:

1. Receive one newline-delimited Pino JSON record at a time.
2. Parse it enough to obtain Pino's `time` field. Convert its millisecond epoch
   to a decimal Unix-nanosecond string for Loki:
   `String(BigInt(record.time) * 1_000_000n)`. If `time` is absent or invalid,
   use `Date.now()` at the point the record is received.
3. Preserve the entire Pino JSON record as the Loki line. A Loki line is a
   JSON string, not an object.
4. Batch records for the same static label set into this Loki Push API payload:

   ```json
   {
     "streams": [
       {
         "stream": {
           "client": "<LOG_CLIENT>",
           "project": "<LOG_PROJECT>",
           "service": "<LOG_SERVICE>",
           "environment": "<LOG_ENVIRONMENT>",
           "region": "<optional LOG_REGION>",
           "runtime": "<optional LOG_RUNTIME>"
         },
         "values": [
           ["<unix-nanoseconds>", "<complete Pino JSON line>"],
           ["<unix-nanoseconds>", "<complete Pino JSON line>"]
         ]
       }
     ]
   }
   ```

   Omit `region` and `runtime` when not configured; never send their values as
   `undefined`, `null`, or empty labels.
5. POST to `LOG_ENDPOINT` using `Content-Type: application/json` and HTTP
   Basic Auth from `LOG_USERNAME` and `LOG_PASSWORD`. Prefer native `fetch` on
   supported Node versions; otherwise use the project's existing HTTP client.
6. Bound memory and request size. Start with all of: flush every 1 second,
   flush at 100 records, cap the in-memory queue at 5,000 records, and ensure a
   serialized HTTP body remains below 900 KiB (the server default maximum is
   1 MiB). Split a batch when adding the next record would exceed the cap.
7. Use a short network timeout (5 seconds is appropriate) through
   `AbortSignal.timeout` or an equivalent abort controller.
8. On transient delivery failure (network error, timeout, HTTP `429`, or HTTP
   `5xx`), retry asynchronously with exponential backoff and jitter. A sensible
   initial schedule is 500 ms, 1 s, 2 s, 4 s, then capped at 30 s. Limit
   attempts and the total retry window (for example, 10 attempts or 5 minutes)
   so memory cannot grow indefinitely.
9. For an invalid endpoint, HTTP `401`, `403`, or other non-retryable `4xx`,
   drop that batch rather than retrying it forever. For a `413`, reduce/split
   the batch; if one record still cannot fit, drop only that record.
10. When a queue or retry window is exhausted, drop the oldest or failed batch
    according to a documented policy, increment an in-process counter, and
    write an occasional rate-limited diagnostic to `stderr`. The diagnostic
    must not be re-enqueued to Loki (avoid recursion) and must not reveal
    credentials or record contents.
11. Never `await` delivery on the application request path. `write()` to the
    Pino destination must return promptly.
12. On `SIGTERM`, `SIGINT`, and the application's normal graceful-shutdown
    route, stop accepting new application work, then call `await logger.flush()`
    with a short hard deadline (for example, 5 seconds). Keep stdout functional
    even if the deadline expires. Do not delay process exit indefinitely.

The batcher's internal timers should be `unref()`'d if that is compatible with
the implementation, so logging alone does not keep an otherwise idle process
alive.

### 3. Use the shared logger everywhere

Wire the shared logger into the application rather than adding a second logging
API. At minimum, update:

- application bootstrap and configuration/startup failures;
- HTTP framework request/error logging (use the framework's Pino integration
  when available, such as Fastify's built-in logger or an Express middleware);
- route handlers and service/domain code currently using `console.*`;
- queue consumers, cron jobs, workers, and scheduled task failures;
- database/cache/third-party-client error paths where the application logs;
- `uncaughtException` and `unhandledRejection` handlers, which must log the
  error then use the application's established fatal-exit policy;
- graceful shutdown logging and final `flush()`.

Do not create a new remote logger per request, job, module reload, or worker
message. One process-level logger/batcher is required per Node.js process.

For HTTP requests, include safe structured context such as `requestId`, HTTP
method, route template (not a raw high-cardinality URL), status code, and
duration. Do not log request or response bodies by default.

## Security and data hygiene

- Never log passwords, authorization headers, cookies, API keys, OAuth tokens,
  private keys, credentials, OTPs, payment-card data, database dumps, file
  bodies, base64 blobs, or entire third-party responses.
- Keep potentially useful dynamic values—request IDs, user IDs, trace IDs,
  URLs, and error details—inside the JSON log record only.
- Do not log the `Authorization` value used to call Loki, even in debug mode.
- Validate that all configured label values are non-empty, normalized strings
  with bounded length. If labels are invalid, use stdout-only mode and report a
  sanitized local configuration warning.
- Default production level is `info`. Raise to `debug` only temporarily for a
  specific diagnosis, then revert it.

## Tests to add

Use the repository's test framework and mock the HTTP transport. Tests should
not make real network calls or contain usable credentials.

1. A log call produces valid Pino JSON on stdout and an equivalent Loki line.
2. The request uses the exact configured endpoint, `Content-Type:
   application/json`, Basic Auth, and the Loki Push API body shape.
3. The four required labels are present; optional labels are included only when
   configured; dynamic request/user fields never appear as stream labels.
4. Multiple records are batched; oversized batches split below the configured
   request cap.
5. `info`, `warn`, `error`, and an `err` object retain structured level,
   message, and error information in the JSON line.
6. Redaction removes/censors every listed sensitive field, including nested
   headers and cookies, before both stdout and the Loki payload.
7. A timeout, DNS/network error, `429`, and `5xx` retry without blocking the
   calling request; non-retryable `401`/`403` are bounded and dropped.
8. Queue overflow and a permanently unavailable endpoint do not cause unbounded
   memory growth, unhandled promise rejections, or process crashes.
9. `flush()` drains a pending batch when delivery succeeds and obeys its
   shutdown deadline when it does not.
10. Existing HTTP/job failure tests prove that relevant `console.*` call sites
    have been migrated to the shared logger.

## Manual acceptance check (performed with real values supplied out of band)

1. Set the `LOG_*` values in the application's deployment secret store and
   deploy/restart one instance.
2. Trigger an ordinary request or job and a controlled handled error. Confirm
   normal application behaviour and stdout logs first.
3. In Grafana Explore, query the exact stream:

   ```logql
   {client="<LOG_CLIENT>", project="<LOG_PROJECT>", service="<LOG_SERVICE>", environment="<LOG_ENVIRONMENT>"}
   ```

4. Confirm the records parse with `| json`, and confirm errors with:

   ```logql
   {client="<LOG_CLIENT>", project="<LOG_PROJECT>"} | json | level="error"
   ```

5. Verify a request ID or other dynamic field is visible inside the JSON record
   but is **not** a Loki label.
6. Temporarily give the application an invalid Loki password or block egress
   in a non-production environment. Confirm requests/jobs still succeed, stdout
   still logs, remote delivery diagnostics are rate-limited and sanitized, and
   the process does not accumulate memory or hang on shutdown. Restore the
   correct configuration afterward.

## Deliverables

- Shared Pino logger and bounded asynchronous Loki batcher/transport.
- Migration of all application-owned logging call sites and framework hooks to
  the shared logger.
- Graceful shutdown integration with bounded `flush()`.
- Tests covering the cases above.
- A short README/configuration addition listing the required `LOG_*` variables
  by name only (no secret values) and the Grafana query used to verify delivery.
