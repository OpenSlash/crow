# Crow Cloud Storage Adapters

Crow Cloud should not bind product logic to one database. Storage is behind `internal/store.Store`.

## Adapter Interface

```text
Store
  ActivateDevice
  GetEntitlement
  RecordUsage
```

Current implementation:

```text
CROW_CLOUD_STORE=memory
```

Planned implementations:

```text
CROW_CLOUD_STORE=firestore
CROW_CLOUD_STORE=postgres
```

`neon` can be an alias of the Postgres adapter because Neon is hosted PostgreSQL.

## Firestore Fit

Firestore is good for:

```text
MVP
Cloud Run native deployment
simple user/device/subscription documents
daily usage aggregation
low operational overhead
```

Suggested collections:

```text
users/{user_id}
devices/{device_id}
entitlements/{user_id}
subscriptions/{subscription_id}
usage_daily/{user_id_yyyy_mm_dd}
```

## Neon Postgres Fit

Neon Postgres is good for:

```text
relational subscription data
SQL reporting
joins across users/devices/subscriptions
future team/workspace permissions
lower friction if using Stripe-style relational records
```

Suggested tables:

```sql
users
devices
entitlements
subscriptions
usage_daily
usage_events
```

## Local Postgres Test

```bash
docker run --name crow-postgres-test \
  -e POSTGRES_USER=crow \
  -e POSTGRES_PASSWORD=crow \
  -e POSTGRES_DB=crow_test \
  -p 55432:5432 \
  -d postgres:16-alpine

cd server
PORT=18083 \
CROW_CLOUD_STORE=postgres \
CROW_DATABASE_URL='postgres://crow:crow@127.0.0.1:55432/crow_test?sslmode=disable' \
go run ./cmd/crow-cloud
```

The Postgres adapter currently auto-creates:

```text
crow_devices
crow_entitlements
crow_usage_events
crow_usage_daily
```

## Recommendation

Use the adapter boundary from the start:

```text
MVP local/dev: memory
Cloud Run MVP: firestore
Subscription-heavy beta: neon postgres
```

Do not store every tiny audio frame or partial transcript in the database. Store daily aggregates and selected audit events:

```text
stt_seconds
tts_chars
agent_tokens
task_count
approval_count
```
