# Deployment guide

The mail server runs the single-replica API with Docker Compose, alongside its
existing Traefik and Bitwarden services. Kubernetes examples follow below.

## Mail server: install and upgrade

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
valid backup. App exports are separate: use the app's import/share flow to import
conversation backups, rather than extracting them into the server data directory.

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
cd backend/
docker build -t lifenizer-api:latest .
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
| `Products__Premium` | Slug for the Premium product in the payments service | `lifenizer-premium` |
| `Products__PremiumPlus` | Slug for the Premium+ product in the payments service | `lifenizer-premium-plus` |
| `Artifacts__StorePath` | Path to the artifact blob directory | `/data/artifacts` |
| `Whisper__BaseUrl` | Base URL of the self-hosted whisper-trained transcription service | `http://whisper-trained.tab:9000` |
| `Whisper__Language` | Optional default transcription language (ISO code); unset means auto-detect | _(unset)_ |
| `Imports__MaxRequestBytes` | Max request body size accepted by `POST /api/imports/{source}`, to fit base64-encoded audio uploads | `200000000` |

> **Tip:** Inject all secrets via Kubernetes `Secret` objects and reference
> them as environment variables or volume mounts rather than baking them into
> the image.

---

## Storage notes

- **SQLite** supports single-replica deployments. PostgreSQL requires changing
  the EF provider, migrations and SQLite-specific upgrade logic; a different
  connection string alone is insufficient.
- Artifact blobs default to `/tmp/lifenizer-artifacts` (ephemeral).
  In production, mount persistent storage and point `Artifacts__StorePath` at it.
  The example mounts `/data` for both SQLite and artifact files.

---

## Kubernetes deployment example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lifenizer-api
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: lifenizer-api
  template:
    metadata:
      labels:
        app: lifenizer-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      containers:
        - name: api
          image: lifenizer-api:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: Auth__AllowDevLogin
              value: "false"
            - name: Artifacts__StorePath
              value: /data/artifacts
            - name: ConnectionStrings__Lifenizer
              valueFrom:
                secretKeyRef:
                  name: lifenizer-secrets
                  key: db-connection-string
            - name: Jwt__Secret
              valueFrom:
                secretKeyRef:
                  name: lifenizer-secrets
                  key: jwt-secret
            - name: Payments__BaseUrl
              valueFrom:
                secretKeyRef:
                  name: lifenizer-secrets
                  key: payments-base-url
          volumeMounts:
            - name: artifact-storage
              mountPath: /data
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: artifact-storage
          persistentVolumeClaim:
            claimName: lifenizer-artifacts-pvc
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: lifenizer-api
spec:
  selector:
    app: lifenizer-api
  ports:
    - port: 80
      targetPort: 8080
```

### NetworkPolicy (restrict egress)

This example permits DNS and in-cluster HTTPS only. Add destination-specific rules
for the configured Whisper service (TCP 9000), IMAP, or external providers before
using those imports.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: lifenizer-api-netpol
spec:
  podSelector:
    matchLabels:
      app: lifenizer-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - ports:
        - port: 8080
  egress:
    # Allow DNS
    - ports:
        - port: 53
          protocol: UDP
    # Allow in-cluster HTTPS; restrict destinations for your deployment
    - to:
        - namespaceSelector: {}
      ports:
        - port: 443
```

---

## Subscription tiers

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
HTTP redirects are disabled. The API can reach only the destinations its operator configures.
A desktop-hosted API cannot resolve the cluster-only Whisper hostname; set
`Whisper__BaseUrl` to an accessible private endpoint (for a temporary authorized test,
`http://127.0.0.1:19000` through port-forwarding).

Startup adopts both previously shipped SQLite schemas, then applies EF migrations.
Back up the database before an upgrade; see [DATABASE.md](DATABASE.md). Do not scale the
SQLite deployment beyond one replica. This repository does not deploy a Fleet workload
or change the Whisper network policy; a cluster deployment needs those declared separately.
