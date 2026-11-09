#!/usr/bin/env bash
# holder-image-test.sh: build the registry holder image (holder/Dockerfile) and test it locally.
#
#   tools/holder-image-test.sh
#
# A heavy job: run it under the heavy lock (crew-heavy run), never in CI. It needs docker and
# gitleaks. Steps:
#   1. build the image from the pins (pins/ntfy.env, pins/tailscale.env);
#   2. layer scan: nothing secret in `docker history`, `docker inspect`, or the image's
#      filesystem (gitleaks over the exported root);
#   3. smoke run with --network none and stub secrets: tailscale is stubbed (there is no
#      network), ntfy is the real one, bound to the address the stub reports (loopback): the
#      entrypoint must reach its job loop, ntfy must answer, an anonymous topic read must be
#      refused (deny-all), and the process must not be root.
# Exit 0 = all passed. Everything it creates (a temp dir, one image tag, one container) is
# removed at the end.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
for t in docker gitleaks git; do
  command -v "$t" >/dev/null || { echo "holder-image-test: $t is required" >&2; exit 2; }
done

tag=crewkit-holder-test:$$
cname=crewkit-holder-test-$$
tmp=$(mktemp -d)
cleanup() {
  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker rmi -f "$tag" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "== build"
tools/holder-image-build.sh "$tag" >/dev/null

# Secrets used below are fakes, made here. A leak of one into the log is found by name.
canary_ts=tskey-auth-CANARY-0f3a9c
canary_deploy=deploy-key-CANARY-77d1e2

echo "== layer scan"
{ docker history --no-trunc "$tag"; docker inspect "$tag"; } > "$tmp/meta.txt"
if grep -q -i -e 'authkey' -e 'password' -e 'token=' "$tmp/meta.txt"; then
  echo "FAIL: a secret-looking name or value is in the image metadata" >&2
  exit 1
fi
[[ $(docker inspect -f '{{.Config.User}}' "$tag") == crewkit ]] ||
  { echo "FAIL: the image does not run as the crewkit user" >&2; exit 1; }
docker create --name "$cname" "$tag" >/dev/null
mkdir "$tmp/rootfs"
docker export "$cname" | tar -x -C "$tmp/rootfs" 2>/dev/null || true
docker rm -f "$cname" >/dev/null
# An empty or partial export would make the scan pass for nothing.
[[ -x $tmp/rootfs/opt/crewkit/libexec/crewkit-holder-run && -x $tmp/rootfs/usr/local/bin/ntfy ]] ||
  { echo "FAIL: the exported filesystem is incomplete" >&2; exit 1; }
# The default rules plus one allowed path: perl's C headers (a Debian package that git pulls in)
# trip generic-api-key on a macro. Nothing of ours lives there.
cat > "$tmp/gitleaks.toml" <<'TOML'
[extend]
useDefault = true
[allowlist]
paths = ['''usr/lib/[^/]+/perl/.*/CORE/.*\.h''']
TOML
gitleaks dir --no-banner --redact --config "$tmp/gitleaks.toml" "$tmp/rootfs" >/dev/null ||
  { echo "FAIL: gitleaks found a secret in the image filesystem" >&2; exit 1; }
for f in deploy_key ts_authkey ntfy_auth; do
  [[ ! -e $tmp/rootfs/run/secrets/$f ]] || { echo "FAIL: $f is baked into the image" >&2; exit 1; }
done
echo "ok"

echo "== smoke"
secrets=$tmp/secrets
mkdir -p "$secrets/report_keys" "$tmp/stubs" "$tmp/authdb"
printf '%s\n' "$canary_ts" > "$secrets/ts_authkey"
printf '%s\n' "$canary_deploy" > "$secrets/deploy_key"
printf 'report-key-stub\n' > "$secrets/report_keys/n-stub1"
printf 'homebox n-stub1 stub@homebox\n' > "$secrets/nodes"
printf 'homebox ssh-ed25519 AAAAstub\n' > "$secrets/nodes_known_hosts"
# ntfy's own user database, made by the image's own ntfy.
chmod 777 "$tmp/authdb"
# `user add` needs the file to exist, which only a server start creates, so start one briefly.
docker run --rm --network none -v "$tmp/authdb:/out" -e NTFY_PASSWORD=stub-pass \
  -e NTFY_AUTH_FILE=/out/auth.db -e NTFY_AUTH_DEFAULT_ACCESS=deny-all -e NTFY_LISTEN_HTTP=127.0.0.1:18080 \
  --entrypoint /bin/sh "$tag" -c '
    ntfy serve >/dev/null 2>&1 & pid=$!
    for _ in $(seq 20); do [ -s /out/auth.db ] && break; sleep 0.5; done
    kill "$pid"; wait "$pid" 2>/dev/null
    ntfy user add holder' >/dev/null
cp "$tmp/authdb/auth.db" "$secrets/ntfy_auth"
# a local sync repo to clone
git init -q --bare "$tmp/sync.git"
git clone -q "$tmp/sync.git" "$tmp/seed" 2>/dev/null
(cd "$tmp/seed" && git checkout -q -b main && echo '{"schema":1,"registry_id":"r-smoke"}' > registry.json && git add . &&
  git -c user.name=t -c user.email=t@example.com commit -qm seed && git push -q origin main)
git -C "$tmp/sync.git" symbolic-ref HEAD refs/heads/main
# tailscale is stubbed: no network here. tailscaled sleeps; `up` succeeds; `ip` is loopback.
printf '#!/bin/sh\nexec sleep 3600\n' > "$tmp/stubs/tailscaled"
cat > "$tmp/stubs/tailscale" <<'STUB'
#!/bin/sh
for a in "$@"; do case $a in --*) ;; ip) echo 127.0.0.1; exit 0 ;; up) exit 0 ;; esac; done
exit 0
STUB
chmod 755 "$tmp/stubs/tailscaled" "$tmp/stubs/tailscale"
chmod -R a+rX "$tmp/stubs" "$tmp/sync.git"
chmod 700 "$secrets/report_keys"
chmod 600 "$secrets/ts_authkey" "$secrets/deploy_key" "$secrets/ntfy_auth" "$secrets/nodes" "$secrets/nodes_known_hosts" "$secrets/report_keys/n-stub1"

# The secrets are files of this host user, so the container runs as that uid (the image's own
# user, 10001, could not read a mode 600 file of another uid).
uid=$(id -u) gid=$(id -g)
docker run -d --name "$cname" --network none --read-only --user "$uid:$gid" --tmpfs /tmp \
  --tmpfs "/home/crewkit:uid=$uid,mode=700" --tmpfs "/var/lib/crewkit-holder:uid=$uid,mode=700" -e HOME=/home/crewkit \
  -v "$secrets:/run/secrets:ro" -v "$tmp/stubs:/stubs:ro" -v "$tmp/sync.git:/sync.git:ro" \
  -e PATH=/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e CK_REGISTRY_REMOTE=/sync.git -e CK_REGISTRY_ID=r-smoke -e CK_HOLDER_NAME=smoke -e CK_POLL_SECONDS=600 \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  "$tag" >/dev/null

up=0
for _ in $(seq 60); do
  if docker logs "$cname" 2>&1 | grep -q 'job loop started'; then up=1; break; fi
  [[ $(docker inspect -f '{{.State.Running}}' "$cname") == true ]] || break
  sleep 1
done
if ((!up)); then
  echo "FAIL: the entrypoint did not reach its job loop" >&2
  docker logs "$cname" >&2 || true
  exit 1
fi
[[ $(docker exec "$cname" id -u) != 0 ]] || { echo "FAIL: the holder runs as root" >&2; exit 1; }
docker exec "$cname" curl -fsS http://127.0.0.1:8080/v1/health | grep -q '"healthy":true' ||
  { echo "FAIL: ntfy did not answer on its address" >&2; exit 1; }
code=$(docker exec "$cname" curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8080/crewkit-homebox/json?poll=1')
[[ $code == 401 || $code == 403 ]] || { echo "FAIL: an anonymous topic read got $code, not 401/403" >&2; exit 1; }
if docker logs "$cname" 2>&1 | grep -q -e "$canary_ts" -e "$canary_deploy"; then
  echo "FAIL: a secret reached the container log" >&2
  exit 1
fi
echo "ok"
echo "holder-image-test: all passed"
