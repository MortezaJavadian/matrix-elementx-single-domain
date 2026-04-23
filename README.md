# Matrix Element X Single-Domain Setup

Simple Docker setup for a self-hosted Matrix stack on one domain. This project prepares Synapse, Matrix Authentication Service (MAS), LiveKit, Ketesa Admin, and Element Web with clean generated configs, helper scripts, and nginx files.

It is made for fast and repeatable setup with simple prompts and minimal manual work.

## What It Includes

- Synapse
- Matrix Authentication Service (MAS)
- LiveKit for MatrixRTC
- Ketesa Admin
- Element Web
- Nginx config files for an existing `nginx-proxy` container

## Quick Start

Make the script executable and run it:

```bash
chmod +x setup.sh
./setup.sh
```

The script will ask for:

- your server public IP
- your Matrix domain
- allowed admin IPs or CIDRs

## After Setup

### 1. Open Firewall Ports

- Allow UDP `50201-50501`
- Allow TCP `7881`

### 2. Copy Nginx Files

Copy the generated nginx files into your existing `nginx-proxy` config:

```bash
cp "$(pwd)/conf.d/default.conf" ~/nginx-proxy/conf.d/default.conf
cp "$(pwd)/conf.d/snippets/admin-allowlist.inc" ~/nginx-proxy/conf.d/snippets/admin-allowlist.inc
docker exec nginx-proxy nginx -t
docker exec nginx-proxy nginx -s reload
```

To allow another admin IP later, add `allow <IP>;` to `conf.d/snippets/admin-allowlist.inc` and reload nginx.

### 3. Create the First Admin

```bash
./scripts/make-admin.sh
```

### 4. Create Normal Users

Preferred: use Ketesa Admin UI

CLI:

```bash
docker compose exec -it mas mas-cli --config=/data/config.yaml manage register-user
```

### 5. Reclaim a Deleted Username

If a deleted username must be created again:

```bash
./scripts/purge-user.sh
```

## URLs

After setup, your stack will be available at:

- `https://your-domain/` for Element and MAS
- `https://your-domain/web/` for Element Web
- `https://your-domain/admin/` for Ketesa Admin
