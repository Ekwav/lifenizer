# Deployment guide

This document covers deploying the Lifenizer API as a containerised
service in a hardened Kubernetes cluster.

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
