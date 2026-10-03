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
| `ConnectionStrings__Lifenizer` | SQLite connection string (dev) **or** Postgres DSN (prod) | `Data Source=/data/lifenizer.db` |
| `Jwt__Secret` | HS256 signing key (≥ 32 bytes, random) | _(generate with `openssl rand -base64 32`)_ |
| `Auth__AllowDevLogin` | `true` in dev only — **must be `false` in prod** | `false` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to Firebase service account JSON mounted as a secret | `/run/secrets/firebase.json` |
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

- **SQLite** is fine for single-replica deployments.  For multi-replica
  setups, switch to **PostgreSQL** by adding `Npgsql.EntityFrameworkCore.PostgreSQL`
  and updating the connection string.
- Artifact blobs default to `/tmp/lifenizer-artifacts` (ephemeral).
  In production, bind-mount a persistent `PersistentVolumeClaim` or configure
  an object-storage backend and point `Artifacts__StorePath` at the mount path.

---

## Kubernetes deployment example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lifenizer-api
spec:
  replicas: 1
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
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: /run/secrets/firebase/key.json
          volumeMounts:
            - name: firebase-secret
              mountPath: /run/secrets/firebase
              readOnly: true
            - name: artifact-storage
              mountPath: /data/artifacts
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
        - name: firebase-secret
          secret:
            secretName: lifenizer-firebase
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
    # Allow outbound to payments service and Firebase
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
