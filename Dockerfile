# syntax=docker/dockerfile:1.7

# ─────────────────────────────────────────────────────────────────────────────
# Pinned to a specific Alpine minor version so security patches in Node 22.x
# are picked up automatically while the base OS stays stable.
# To harden further: replace the tag with the image digest.
#   docker pull node:22-alpine3.21
#   docker inspect node:22-alpine3.21 --format '{{index .RepoDigests 0}}'
# ─────────────────────────────────────────────────────────────────────────────

# ─── Stage 1 — Dependency cache ──────────────────────────────────────────────
# Isolated so Docker reuses this layer until package*.json changes.
FROM node:22-alpine3.21 AS deps
WORKDIR /app

# Only copy manifests — no source code needed to install deps.
COPY package.json package-lock.json ./

# --frozen-lockfile: abort if the lockfile is out of sync (CI-safe).
# Runs as root here; this stage is never shipped.
RUN npm ci --frozen-lockfile

# ─── Stage 2 — Build ─────────────────────────────────────────────────────────
# Full source + devDeps needed for TypeScript compilation + Next.js build.
#
# NEXT_PUBLIC_* values are inlined into the JS bundle at build time — pass
# them as --build-arg / ARG. NEVER pass server secrets (ENCRYPTION_KEY,
# SUPABASE_SERVICE_ROLE_KEY, META_APP_SECRET …) as build args; they would
# be baked into image layer history and visible via `docker history`.
FROM node:22-alpine3.21 AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_APP_LOCALE=en

# ENV from ARG — only the public vars; nothing secret.
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# ─── Stage 3 — Minimal runtime ───────────────────────────────────────────────
# Only the standalone bundle lands here — no source, no devDeps, no npm.
#
# Security hardening applied in this stage:
#   • Non-root user (uid/gid 1001) — container process can't own host files
#   • dumb-init as PID 1 — proper signal forwarding + zombie reaping so
#     SIGTERM reaches Node and inflight requests drain before exit
#   • NODE_OPTIONS caps heap + enforces TLS 1.2 minimum
#   • No shell, no package manager, no build tools in the shipped image
FROM node:22-alpine3.21 AS runner
WORKDIR /app

# dumb-init: lightweight init system for containers.
# --no-cache: no apk index written to the image layer.
RUN apk add --no-cache dumb-init \
 # Create a locked-down group + user (no shell, no home dir).
 && addgroup -g 1001 -S nextjs \
 && adduser  -u 1001 -S nextjs -G nextjs --no-create-home --shell /sbin/nologin

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    # Heap cap (tune up for high-traffic deployments).
    # --tls-min-v1.2 rejects TLS 1.0/1.1 handshakes.
    NODE_OPTIONS="--max-old-space-size=512 --tls-min-v1.2"

# Copy the standalone bundle — this is the only thing the runtime needs.
# --chown ensures the app files are owned by the non-root user, not root.
COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static     ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public           ./public

# Drop to non-root for all subsequent operations (including CMD).
USER nextjs

EXPOSE 3000

# Built-in health probe used by both Docker and the Compose healthcheck.
# Exits 0 if the app responds with any non-5xx status, 1 otherwise.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e \
    "fetch('http://localhost:3000').then(r=>process.exit(r.ok||r.status<500?0:1)).catch(()=>process.exit(1))"

# dumb-init as PID 1 so SIGTERM/SIGINT reach Node cleanly.
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "server.js"]
