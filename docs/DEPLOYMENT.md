# Deployment guide

Since the verified 2026-10-24 cutover, the API runs in the Fleet cluster at
`https://lifenizer.coflnet.com`. `https://mail.coflnet.com/lifenizer` remains a
transparent compatibility proxy. The old mail-server Compose API stays stopped
so the cluster remains the only SQLite writer.

## Fleet cluster migration

The Fleet chart is the authoritative Kubernetes configuration. Follow
`../fleet/lifenizer/README.md` for the completed migration and gateway prerequisites.
It uses one SQLite writer, a retained encrypted volume, and injected OpenBao
files at `/var/run/secrets/lifenizer`. The API loads those files before configuring
authentication, payments and object storage. Existing Compose deployments need
no secret-file directory.

Create a private R2 bucket and a bucket-scoped **Object Read & Write** token using
[Cloudflare's S3 setup](https://developers.cloudflare.com/r2/get-started/s3/), then run:

```bash
cd ../ansible
./scripts/configure-lifenizer-r2.sh
```

The interactive helper hides the credentials and CAS-patches only the six R2
fields at `kv/services/lifenizer`. It uses Fleet's short-lived child session,
revokes that child, verifies HTTP 403, and removes its credential artifacts.
It does not create the bucket, enable billing, or deploy the application.

Normal updates use cluster image CI for `Coflnet/Lifenizer` on `main`; it does not publish
from the existing personal repository or feature branches. After application
checks, the shared workflow builds, then Argo validates, scans and pins the image
in `lifenizer/app/chart/values.yaml`. Follow `../fleet/argo-workflow/CI.md`, including
independent review where required. Verify Argo promotion, the Fleet image pin,
the workload rollout and public behavior before reporting an update deployed.

For cutover, preserve the current signing key, pairing configuration, complete
SQLite state and local artifacts. Keep `https://mail.coflnet.com/lifenizer` as a
transparent proxy to the cluster, preserving authorization, uploads and streaming
responses. [cluster-alias.yaml](../deploy/cluster-alias.yaml) provides the matching
Traefik file-provider route; activate it after stopping the old API writer and
verifying the cluster endpoint. It strips the existing prefix and uses the new
hostname for upstream TLS and HTTP. Do not redirect or relink existing devices:
their full server URL is part of the local vault and recording-cache identity. Verify playback of the
existing phone recording from the PC before retiring the old backend.

## Legacy Compose: mail server install, upgrade and backup

The Compose instructions below apply only to a separate legacy Compose deployment.
Do not run the installer, backup helper or restore procedure against the migrated
mail-server deployment while the cluster is active. The backup helper restarts the
Compose API even if it was stopped, which would create a second SQLite writer.

Run from a clean, reviewed commit on the KDE machine:

```bash
./scripts/deploy-compose.py
```

Requirements: Docker, Python 3, SSH access to `mail.coflnet.com`, Trivy, and
`qrencode`. The server needs Docker Compose v2, its existing `proxy` Docker
network and `traefik` container. No registry credentials or cluster credentials
are copied to the mail server.

The installer builds the API image, rejects fixable high/critical vulnerabilities,
loads the image over SSH, and deploys [compose.yaml](../deploy/compose.yaml) into
`~/dev/lifenizer-next`. It preserves the older `~/dev/lifenizer` checkout and
Bitwarden. The API has no published host port: Traefik serves it at
`https://mail.coflnet.com/lifenizer`, strips that prefix, and forwards to port 8080.
Only Traefik's current exact IP is trusted for forwarded headers. Run the installer
again after recreating Traefik if its Docker address changes.

The resulting connection link and QR code configure the server, account and vault
without typing passwords. Open the link on the first device within one hour, then
keep it unlocked while connecting the next. After the hour, an unlocked paired
device must approve each new device. An unclaimed installation cannot be claimed
after its deadline. Redeployment never silently extends that deadline.

The private installer identity and QR are saved under
`${XDG_STATE_HOME:-$HOME/.local/state}/lifenizer/compose` with owner-only access.
Preserve `pairing.json` when moving deployment to another computer. The server gets
only a hash of a derived enrollment proof; it never receives the link secret or
the vault passphrase. Device credentials use Android secure storage or KDE's Secret
Service. See [AUTH.md](AUTH.md) for the pairing and recovery model.

```bash
./scripts/deploy-compose.py --show-link  # Print the same link; does not extend time
./scripts/deploy-compose.py --backup-only
```

SQLite and encrypted artifacts persist in `~/dev/lifenizer-next/data`. Before every
upgrade, the installer briefly stops the API to archive data and configuration
consistently, then restarts it. Backups live in the server's private `backups`
directory; they include the signing secret and must stay private. Keep a separate
copy off the server. These archives restore the server and encrypted data; a
paired device's keyring is still needed to decrypt the vault.

To restore, stop the API and move its current `data`, `.env`, and `compose.yaml`
into a separate private recovery directory. Extract the selected archive back into
`~/dev/lifenizer-next`, then run `docker compose up -d` there with the archived image
available. Keep its existing `whisper` directory in place. Copying a live SQLite file without its WAL is not a
valid backup. App exports are separate: use **Sync → Make backup** and
**Sync → Restore backup** for encrypted `.lfb` parts. Legacy conversation JSON
backups use **Imports**. Do not extract app exports into the server data directory.

## Private R2/S3 online storage

Create a private Cloudflare R2 bucket with public access disabled. Create an S3
access key scoped to that bucket with object read/write permissions (including
object deletion); the API needs no account administration credentials. For another
S3-compatible service, use its HTTPS endpoint, bucket and signing region.

Keep a JSON file outside the checkout, owned by the deploying user with mode
`0600` (or stricter). Its supported fields are:

```json
{
  "ObjectStorage__ServiceUrl": "https://ACCOUNT_ID.r2.cloudflarestorage.com",
  "ObjectStorage__Bucket": "lifenizer-private",
  "ObjectStorage__AccessKeyId": "R2_ACCESS_KEY_ID",
  "ObjectStorage__SecretAccessKey": "R2_SECRET_ACCESS_KEY",
  "ObjectStorage__Region": "auto",
  "ObjectStorage__Prefix": "lifenizer"
}
```

Replace the placeholders with the bucket credentials, then deploy a reviewed
commit using the existing installer:

```bash
chmod 600 /private/path/lifenizer-service.json
./scripts/deploy-compose.py --service-config /private/path/lifenizer-service.json
```

`Region` defaults to `auto` for R2; `Prefix` is optional. The installer accepts
only the six object-storage fields above, `Payments__BaseUrl`, `Payments__FreePremiumEnabled`, `Products__Premium`
and `Products__PremiumPlus`. Values must be JSON scalars other than null and safe
unquoted dotenv values: single-line printable ASCII without whitespace, quotes,
backslashes, `$` or `#`. Unsupported fields, unsafe values, symlinks and files with
access for other users are rejected before building or contacting the server.
Credentials travel inside the SSH stdin payload, never in command arguments or
installer logs. The remote helper validates them again, reads the current `.env`,
backs it up with the data, patches only supplied fields and atomically replaces it
with owner-only permissions. Omitted fields retain their current values; later
upgrades can omit `--service-config` entirely.

With object storage configured, new encrypted photos, opted-in recordings and
batched encrypted sync payloads go into private objects. SQLite retains the sync
cursor, object references and account/quota metadata. The API authorizes reads;
clients do not receive bucket credentials. Existing inline SQLite sync payloads
and local media files remain readable; enabling R2 does not migrate or delete them.
Without object-storage configuration, the same object adapter uses the persistent
artifact directory.

Clients save edits locally immediately and collect at least 20 seconds of changes
before an automatic batch upload. One new object stores each accepted sync batch;
retrying already committed envelope IDs does not create duplicate sync objects.
**Sync now** bypasses the delay. Recording storage stays an explicit per-recording
choice: **Store encrypted recording online** makes playback independent of the
source device. Failed uploads/removals keep their requested state encrypted on
that device and retry during ordinary sync while unlocked. Pending storage is
shown separately from confirmed online storage, and removing the online copy
keeps local audio.

The installer archive includes SQLite, configuration and legacy local files;
R2 objects need a separate bucket backup/retention policy. Preserve both the
SQLite references and their referenced objects when restoring a deployment.
Once object-backed sync rows exist, the database migration refuses downgrade
instead of dropping their references. Roll back by restoring the consistent
pre-upgrade backup and its matching server image.
New sync batch objects count toward the same storage allowance as images and
online recordings; existing inline SQLite history remains uncharged.
Payment checkout additionally needs the operator to register the actual product
slugs and configure the payments URL and product settings below; deploying R2
credentials does not configure billing.

## Private transcription relay

The mail API can use the existing KDE-to-Whisper tunnel without exposing Whisper
publicly or copying Rancher credentials:

```bash
./integrations/kde/install-api.sh --with-whisper-forward
./integrations/kde/install-whisper-relay.sh
```

The relay creates `~/dev/lifenizer-next/whisper/asr.sock` over SSH. Compose mounts
its private directory and `Whisper__UnixSocketPath` connects only through that
socket. The relay reconnects under the user systemd session. The socket grants
access only to the operator/container user; no mail-server TCP port is opened.
Whisper transcription requires the KDE machine, its user services and the existing
Rancher tunnel to stay online. Encrypted sync is hosted on the mail server and
continues independently. Recordings remain encrypted local drafts when transcription
is unavailable and can be retried later.

Build the native clients for this deployment before installing them:

```bash
cd app
flutter build linux --release --dart-define=LIFENIZER_API_URL=https://mail.coflnet.com/lifenizer
flutter build apk --release --dart-define=LIFENIZER_API_URL=https://mail.coflnet.com/lifenizer
cd ..
./integrations/kde/install.sh
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
```

The connection link supplies the URL as well, so it works with clients built using
another default. The Android release currently uses the repository's development
signing configuration; preserve that signing key for updates to existing installs.

To update a phone without USB, publish the built APK after deploying this Compose
configuration:

```bash
./scripts/deploy-compose.py --publish-apk app/build/app/outputs/flutter-apk/app-release.apk
```

Open `https://mail.coflnet.com/lifenizer/downloads/lifenizer.apk` on the phone and
install the update over the existing app. The public download contains the app
binary only; existing pairing and encrypted vault data remain on the device.
Publishing verifies the upload checksum, replaces the APK atomically, and checks
the HTTPS range download. The API mounts the downloads directory read-only and
serves only the fixed APK filename.

---

## Building the container image

```bash
# From the repository root:
docker build -f backend/Dockerfile -t lifenizer-api:latest .
```

The multi-stage build produces a minimal Alpine-based runtime image that
runs as a **non-root user** (uid 1001) with no unnecessary capabilities.

---

## Required environment variables / secrets

| Variable | Description | Example |
|---|---|---|
| `ConnectionStrings__Lifenizer` | SQLite connection string (single replica; PostgreSQL requires a provider change) | `Data Source=/data/lifenizer.db` |
| `Jwt__Secret` | HS256 signing key (≥ 32 bytes, random) | _(generate with `openssl rand -base64 32`)_ |
| `Auth__AllowDevLogin` | `true` in dev only — **must be `false` in prod** | `false` |
| `Auth__EnableFirebase` | Optional Google authentication, disabled by default | `false` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Credential file only used when Firebase is explicitly enabled | `/run/secrets/firebase.json` |
| `Payments__BaseUrl` | Base URL of the Coflnet payments service | `https://payments.example.com` |
| `Payments__FreePremiumEnabled` | Offer explicit free 10 GB Premium activation to signed-in accounts; disabled by default, paid checkout paused while enabled | `false` |
| `Products__Premium` | Slug for the Premium product in the payments service | `lifenizer-premium` |
| `Products__PremiumPlus` | Slug for the Premium+ product in the payments service | `lifenizer-premium-plus` |
| `Artifacts__StorePath` | Persistent local object/legacy artifact directory | `/data/artifacts` |
| `ObjectStorage__ServiceUrl` | Optional S3-compatible HTTPS endpoint; configure with bucket and credentials | `https://ACCOUNT_ID.r2.cloudflarestorage.com` |
| `ObjectStorage__Bucket` | Private object-storage bucket | `lifenizer-private` |
| `ObjectStorage__AccessKeyId` | Bucket-scoped object read/write access key | _(secret)_ |
| `ObjectStorage__SecretAccessKey` | Corresponding secret access key | _(secret)_ |
| `ObjectStorage__Region` | S3 signing region; R2 uses `auto` | `auto` |
| `ObjectStorage__Prefix` | Optional object-key prefix within the bucket | `lifenizer` |
| `Whisper__BaseUrl` | Base URL of the self-hosted whisper-trained transcription service | `http://whisper-trained.tab:9000` |
| `Whisper__Language` | Optional default transcription language (ISO code); unset means auto-detect | _(unset)_ |
| `Imports__MaxRequestBytes` | Max request body size accepted by `POST /api/imports/{source}`, to fit base64-encoded audio uploads | `200000000` |
| `Training__Tab__BaseUrl` | TAB notice, anonymous consent, selected speech contributions and consent withdrawal | `https://tab.coflnet.com` |

> **Tip:** Inject all secrets via Kubernetes `Secret` objects and reference
> them as environment variables or volume mounts rather than baking them into
> the image.

---

## Storage notes

- **SQLite** supports single-replica deployments. PostgreSQL requires changing
  the EF provider, migrations and SQLite-specific upgrade logic; a different
  connection string alone is insufficient.
- Without R2/S3 configuration, object blobs default to `/tmp/lifenizer-artifacts` (ephemeral).
  In production, mount persistent storage and point `Artifacts__StorePath` at it.
  The example mounts `/data` for both SQLite and artifact files.

---

## Subscription tiers

For the temporary free Premium rollout, set `Payments__FreePremiumEnabled=true`.
The flag offers an upgrade; it does not automatically grant storage. Signed-in
users open **Plans** or **Sync → Upgrade for more storage**, confirm the displayed
account/server and choose **Activate free Premium**. The authenticated
`POST /api/premium/activate` saves an idempotent activation timestamp on that
existing account; its user ID, vault ID, vault salt and stored data stay unchanged.
After activation, the same quota service used by uploads and sync grants 10 GB.
The activation survives server restarts and is visible through
`GET /api/premium/status` as `freePremiumActivatedAt`. No payment service or card
is required for this self-hostable offer. With the flag disabled (the default),
activation is unavailable and accounts retain normal configured payment tiers.
Configured paid subscriptions (including Premium+ with 100 GB) retain their
entitlements. Disable the flag to return to normal payment-based tiers; activation
timestamps remain stored and no account is automatically charged. Existing stored
data stays accessible if usage exceeds the restored limit, and further uploads
are blocked. The flag is also supported by the Compose service-config flow.

Authenticated users can opt out with `POST /api/premium/cancel-free`, including
when the offer flag is disabled. Cancellation clears the free-offer activation;
if the account becomes Free, it schedules online storage deletion 30 days later.
The nullable ISO 8601 `onlineStorageDeleteAt` in every premium quota response
persists across restarts; retries preserve the original deadline. Calls from an
account that never activated the offer do not schedule deletion. Migration leaves
existing accounts unscheduled, including cancellations made before this policy;
it does not retroactively schedule deletion. The quota
immediately returns to 50 MB, and stored data remains readable until cleanup.
Back up or download online data before the displayed deadline.

An hourly worker (also run at startup after schema migration) deletes due sync
batch objects and legacy inline sync rows, image objects, encrypted recording
objects and their metadata, and resets storage usage. It supports configured R2
and local storage alike. The account, authentication, vault identity, pairing,
usage events and feedback remain intact. No deletion tombstones are sent to
local vaults: data already saved on devices is unaffected. Images may exist only
online. Uploads remain blocked after the deadline until reactivation. Reactivating
before cleanup clears the schedule; doing so after deletion enables uploads but
cannot restore deleted online objects or automatically republish old sync history.

Cancellation never modifies a provider-backed subscription. A fresh paid
entitlement prevents scheduling and cancels any pending deletion. Cleanup freshly
verifies payment entitlements while holding the SQLite write transaction that
serializes activation, uploads and other cleanup replicas. Provider errors stop
deletion; object deletion errors preserve all database references and the deadline
for idempotent retry. A provider outage during cancellation returns 503 without
changing the activation; retry when the provider is available.

After successful cancellation, clients may optionally send authenticated
`POST /api/premium/cancellation-feedback` with `{ "feedback": "..." }`. Feedback
is trimmed, must contain 1–2000 characters, and is stored as a
`premium_cancellation_feedback` usage event. Success returns 204; invalid input
returns 400. Feedback is not sent to an external service.

| Plan | Price | Storage |
|---|---|---|
| Free (default) | — | 50 MB |
| Premium | €4.99 / month | 10 GB |
| Premium+ | €19.99 / month | 100 GB |

Product slugs must be registered in the Coflnet payments service before
going live:

- `lifenizer-premium`
- `lifenizer-premium-plus`

The `POST /api/premium/checkout/{plan}` endpoint redirects users to a
LemonSqueezy checkout page.  After a successful payment, the payments
service will mark the product as owned; the next call to
`GET /api/premium/status` will reflect the upgraded tier (cached for 5 min).

## Local self-hosted runtime

`./scripts/run-api.sh` starts a production-mode API on `http://127.0.0.1:5075`,
generates a private persistent signing key, and stores SQLite/artifacts under
`${XDG_STATE_HOME:-$HOME/.local/state}/lifenizer`. It disables development login.
Set `LIFENIZER_BIND_URL` only when intentionally exposing the API through a private
network or HTTPS reverse proxy. `Cors__AllowedOrigins__0` configures the web origin;
native Linux/Android clients do not use browser CORS.

Provider hosts are configuration-only: `Imports__Imap__Host` (plus Port/UseTls),
`Imports__Paperless__BaseUrl`, `Imports__Discord__BaseUrl`, and `Imports__YouTube__BaseUrl`.
HTTP redirects are disabled. The API can reach only the destinations its operator configures
(plus youtube.com when the built-in caption fetcher is enabled, see below).

`Imports__YouTube__BuiltInCaptions` (default `true`) lets `youtube-transcript` fetch public captions
directly from YouTube when `Imports__YouTube__BaseUrl` is not set; a configured BaseUrl always takes
precedence. This is best effort and may break when YouTube changes its page. Privacy: YouTube sees
the server IP and the video id, not the user. Set it to `false` to forbid outbound calls to YouTube.
TikTok has no equivalent. Details: [IMPORTERS.md](IMPORTERS.md).
A desktop-hosted API cannot resolve the cluster-only Whisper hostname; set
`Whisper__BaseUrl` to an accessible private endpoint (for a temporary authorized test,
`http://127.0.0.1:19000` through port-forwarding).

Startup adopts both previously shipped SQLite schemas, then applies EF migrations.
Back up the database before an upgrade; see [DATABASE.md](DATABASE.md). Do not scale the
SQLite deployment beyond one replica. This repository does not deploy a Fleet workload
or change the Whisper network policy; a cluster deployment needs those declared separately.
