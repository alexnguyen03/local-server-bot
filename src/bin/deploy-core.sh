#!/usr/bin/env bash
# Deploy core: mirror GHCR -> CS registry, then redeploy via Dockhand and wait for health.
# Copied by `deploy` into each component's .run/ and run alongside a .env it builds.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$HERE/compose.yaml}"

[ -f "$ENV_FILE" ]     || { echo "env not found: $ENV_FILE" >&2; exit 1; }
[ -f "$COMPOSE_FILE" ] || { echo "compose not found: $COMPOSE_FILE" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a

TAG="${1:?usage: bash deploy.sh <tag>   (e.g.: sha-737d48a)}"
PULL_REGISTRY="${PULL_REGISTRY:-localhost:5000}"   # registry name as seen from CS
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
CLEANUP="${CLEANUP:-1}"          # 1 = after a good deploy, delete old tags on the CS registry (keep the new build + 1 prior one to restore)
HOST_PRUNE="${HOST_PRUNE:-0}"    # 1 = also ask Dockhand to prune every unused image on the CS host (see the warning in the docs)
ROLLBACK_HEALTH_TIMEOUT="${ROLLBACK_HEALTH_TIMEOUT:-60}"   # rollback waits less: the old build already ran fine before
STATE_FILE="${STATE_FILE:-$HOME/.ls-deploy-last-good-$DOCKHAND_STACK}"

missing=()
for v in GH_REPO APP CS_REGISTRY REG_USER REG_PASS GH_USER GHCR_PAT \
         DOCKHAND_URL DOCKHAND_ENV_ID DOCKHAND_STACK DOCKHAND_USER DOCKHAND_PASS; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
[ ${#missing[@]} -eq 0 ] || { echo "Missing or empty: ${missing[*]}" >&2; exit 1; }
[ -n "${HEALTH_URL:-}" ] || echo ">> HEALTH_URL is empty: will check the stack's containers instead of an HTTP health check"

JAR=$(mktemp); LOG=$(mktemp)
trap 'rm -f "$JAR" "$LOG"' EXIT
T_ALL=$SECONDS

SRC_CREDS=(--creds "$GH_USER:$GHCR_PAT")
DST_CREDS=(--tls-verify=false --creds "$REG_USER:$REG_PASS")

mb() { awk -v b="${1:-0}" 'BEGIN{printf "%.0f", b/1048576}'; }

# Total layer size of the source image (bytes); 0 if it's a manifest list or can't be read
src_size() {
  skopeo inspect --raw "${SRC_CREDS[@]}" "docker://ghcr.io/$GH_REPO:$1" 2>/dev/null \
    | jq -r '[.layers[]?.size] | add // 0' 2>/dev/null || echo 0
}

mirror() {
  if [ "${SKIP_MIRROR:-0}" = 1 ]; then
    skopeo inspect "${DST_CREDS[@]}" --format '{{.Digest}}' "docker://$CS_REGISTRY/$APP:$1" >/dev/null 2>&1 \
      || { echo "!! $APP:$1 is not on the CS registry (not built on LS yet, or already pruned past the 2 kept builds)" >&2; return 1; }
    echo ">> mirror: skipped, the build made on LS is already on CS ($APP:${1:0:12})"
    return 0
  fi
  local src="docker://ghcr.io/$GH_REPO:$1" dst="docker://$CS_REGISTRY/$APP:$1" t=$SECONDS sd dd size
  echo ">> mirror ghcr.io/$GH_REPO:$1 -> $CS_REGISTRY/$APP:$1"
  sd=$(skopeo inspect --retry-times 2 "${SRC_CREDS[@]}" --format '{{.Digest}}' "$src" 2>&1) \
    || { echo "!! could not read $src: ${sd:0:200} (check GHCR_PAT, or whether the tag exists)" >&2; return 1; }
  dd=$(skopeo inspect "${DST_CREDS[@]}" --format '{{.Digest}}' "$dst" 2>/dev/null || true)
  if [ -n "$dd" ]; then echo ">> GHCR digest ${sd:7:12}; on CS: ${dd:7:12}"
  else echo ">> GHCR digest ${sd:7:12}; on CS: this tag doesn't exist yet"; fi
  if [ -n "$dd" ] && [ "$sd" = "$dd" ]; then
    echo ">> mirror: CS already has this exact image, skipping the copy ($((SECONDS - t))s)"
    return 0
  fi
  size=$(src_size "$1"); size=${size:-0}
  [ "$size" -gt 0 ] 2>/dev/null && echo ">> image ~$(mb "$size") MB (only pushing layers CS doesn't already have)"
  skopeo copy --all --preserve-digests --retry-times 3 --dest-tls-verify=false \
    --src-creds "$GH_USER:$GHCR_PAT" \
    --dest-creds "$REG_USER:$REG_PASS" \
    "$src" "$dst"
  local el=$((SECONDS - t))
  echo ">> mirror done in ${el}s"
}

login() {
  jq -n --arg u "$DOCKHAND_USER" --arg p "$DOCKHAND_PASS" '{username:$u,password:$p}' \
  | curl -fsS -m 20 -c "$JAR" -X POST "$DOCKHAND_URL/api/auth/login" \
      -H 'Content-Type: application/json' -d @- >/dev/null \
  || { echo "!! Dockhand login failed ($DOCKHAND_URL)" >&2; return 1; }
}

# Only replaces the image: ${API_IMAGE...} line; every other ${VAR} is left as-is for Dockhand to fill in
render_compose() {
  local img="$PULL_REGISTRY/$APP:$1" out
  out=$(sed -E 's#^([[:space:]]*image:[[:space:]]*)\$\{API_IMAGE[^}]*\}#\1'"$img"'#' "$COMPOSE_FILE")
  grep -Fq "image: $img" <<<"$out" \
    || { echo "!! Could not replace the image line: check \${API_IMAGE...} in $COMPOSE_FILE" >&2; return 1; }
  if grep -Eq '^[[:space:]]*image:.*ghcr\.io' <<<"$out"; then
    echo "!! compose still has a ghcr.io image, CS won't be able to pull it" >&2; return 1
  fi
  printf '%s\n' "$out"
}

redeploy() {
  local compose t=$SECONDS; compose=$(render_compose "$1") || return 1
  : > "$LOG"
  echo ">> redeploy $DOCKHAND_STACK -> $1"
  jq -n --arg c "$compose" '{content:$c, restart:true}' \
  | curl -fsS -N -m 120 -b "$JAR" -X PUT \
      "$DOCKHAND_URL/api/stacks/$DOCKHAND_STACK/compose?env=$DOCKHAND_ENV_ID" \
      -H 'Content-Type: application/json' -d @- | tee "$LOG" || return 1
  echo
  echo ">> Dockhand accepted the request after $((SECONDS - t))s"
  # SSE always returns HTTP 200: an empty log or a success:false/error in it both count as a failure
  [ -s "$LOG" ] || { echo "!! Dockhand returned an empty response" >&2; return 1; }
  if grep -Eq '"success" *: *false|"error"' "$LOG"; then echo "!! Dockhand reported an error: $(head -c 400 "$LOG")" >&2; return 1; fi
  return 0
}

# Containers of the stack per Dockhand (GET /api/containers): named <stack>-<service>-N, prints "name=state"
containers_of_stack() {
  curl -fsS -m 10 -b "$JAR" "$DOCKHAND_URL/api/containers?env=$DOCKHAND_ENV_ID&all=true" 2>/dev/null \
    | jq -r --arg p "${DOCKHAND_STACK}-" '
        (if type=="array" then . else (.containers // .data // []) end)
        | map(select((.name // "") | ltrimstr("/") | startswith($p)))
        | .[] | "\(.name | ltrimstr("/"))=\(.state // .status // "?")"' 2>/dev/null || true
}
stack_state() { local l; l=$(containers_of_stack | paste -sd' ' -); echo "${l:-no containers for this stack}"; }

# No HEALTH_URL: consider it done once the stack's containers are actually in the running state
wait_running() {
  local start=$SECONDS end=$((SECONDS + ${CONTAINER_TIMEOUT:-90})) next=$((SECONDS + 15)) st
  echo ">> no HEALTH_URL, checking the containers of stack '$DOCKHAND_STACK' instead (up to ${CONTAINER_TIMEOUT:-90}s)"
  while [ "$SECONDS" -lt "$end" ]; do
    st=$(stack_state)
    if grep -Eq '=(running|Up)' <<<"$st"; then echo ">> container is running after $((SECONDS - start))s: $st"; return 0; fi
    if [ "$SECONDS" -ge "$next" ]; then echo ">> still no running container after $((SECONDS - start))s: $st"; next=$((SECONDS + 15)); fi
    sleep 3
  done
  echo "!! after ${CONTAINER_TIMEOUT:-90}s stack '$DOCKHAND_STACK' still has no running container: $(stack_state). Dockhand couldn't run 'compose up': check the dockhand container's log (usually a missing required variable, an external network, or the image pull)" >&2
  return 1
}

wait_healthy() {
  [ -n "${HEALTH_URL:-}" ] || { wait_running; return; }
  echo ">> waiting on $HEALTH_URL (up to ${HEALTH_TIMEOUT}s)"
  local start=$SECONDS end=$((SECONDS + HEALTH_TIMEOUT)) last="" code next=$((SECONDS + 30)) st
  while [ "$SECONDS" -lt "$end" ]; do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || true)
    case "$code" in 2??) echo ">> health OK after $((SECONDS - start))s"; return 0 ;; esac
    last="${code:-000}"
    if [ "$SECONDS" -ge "$next" ]; then
      st=$(stack_state || true)
      echo ">> not up yet after $((SECONDS - start))s: HTTP $last${st:+, Dockhand: $st}"
      next=$((SECONDS + 30))
    fi
    sleep 5
  done
  st=$(stack_state || true)
  echo "!! health never came up after ${HEALTH_TIMEOUT}s: HTTP $last (000 = couldn't connect: container not running, wrong port, or a proxy/DNS issue)${st:+; Dockhand: $st}" >&2
  return 1
}

# Clean up old tags on the CS registry: keep the build just deployed ($1) and the prior good one ($2, for restores).
# Only touches tags the pipeline created (sha-xxxxxxx or a 40-char hex); never jeopardizes the deploy's result.
cleanup_old() {
  local keep_new="$1" keep_prev="${2:-}" dst="$CS_REGISTRY/$APP" tags t d kd="" del=0 out
  [ "$CLEANUP" = 1 ] || { echo ">> image cleanup: disabled (CLEANUP=0)"; return 0; }
  local c=(--tls-verify=false --creds "$REG_USER:$REG_PASS")
  tags=$(skopeo list-tags "${c[@]}" "docker://$dst" 2>/dev/null | jq -r '.Tags[]?' 2>/dev/null) \
    || { echo ">> image cleanup: could not list tags for $dst, skipping"; return 0; }
  for t in $keep_new $keep_prev; do
    d=$(skopeo inspect "${c[@]}" --format '{{.Digest}}' "docker://$dst:$t" 2>/dev/null || true)
    [ -n "$d" ] && kd="$kd $d"
  done
  for t in $tags; do
    [ "$t" = "$keep_new" ] && continue
    [ -n "$keep_prev" ] && [ "$t" = "$keep_prev" ] && continue
    [[ "$t" =~ ^(sha-[0-9a-f]{7}|[0-9a-f]{40})$ ]] || continue
    d=$(skopeo inspect "${c[@]}" --format '{{.Digest}}' "docker://$dst:$t" 2>/dev/null || true)
    # same digest as a build we're keeping: deleting it by digest would delete that one too, so skip it
    if [ -n "$d" ] && [[ " $kd " == *" $d "* ]]; then echo ">> cleanup: keeping $APP:$t (same content as a build being kept)"; continue; fi
    if out=$(skopeo delete "${c[@]}" "docker://$dst:$t" 2>&1); then
      del=$((del + 1)); echo ">> cleanup: deleted $APP:${t:0:12}"
    elif grep -qiE '405|unsupported|not allowed|disabled' <<<"$out"; then
      echo ">> cleanup: the registry doesn't allow deletes yet. Set REGISTRY_STORAGE_DELETE_ENABLED=true on the CS container registry and run again"; break
    elif ! grep -qiE '404|not found|unknown' <<<"$out"; then
      echo ">> cleanup: could not delete $APP:${t:0:12}: ${out: -160}"
    fi
  done
  echo ">> image cleanup done: deleted $del old tag(s) (kept ${keep_new:0:12}${keep_prev:+ and ${keep_prev:0:12}})"
}

# Optional: ask Dockhand to delete every image NOT used by any container on the CS host (docker image prune -a).
host_prune() {
  [ "$HOST_PRUNE" = 1 ] || return 0
  if curl -fsS -m 30 -b "$JAR" -X POST "$DOCKHAND_URL/api/prune/images?env=$DOCKHAND_ENV_ID&dangling=false" >/dev/null 2>&1; then
    echo ">> pruning unused images on the CS host: request sent, Dockhand runs it in the background"
  else
    echo ">> pruning images on the CS host: the call to Dockhand failed, skipping"
  fi
}

mirror "$TAG"
login

if redeploy "$TAG" && wait_healthy; then
  PREV_GOOD=$(cat "$STATE_FILE" 2>/dev/null || true)
  [ -n "$PREV_GOOD" ] && [ "$PREV_GOOD" != "$TAG" ] && echo "$PREV_GOOD" > "$STATE_FILE.prev"
  echo "$TAG" > "$STATE_FILE"
  echo ">> done: $APP:$TAG (total $((SECONDS - T_ALL))s)"
  KEEP_PREV=$(cat "$STATE_FILE.prev" 2>/dev/null || true); [ "$KEEP_PREV" = "$TAG" ] && KEEP_PREV=""
  cleanup_old "$TAG" "$KEEP_PREV" || true
  host_prune || true
else
  echo "!! deploy or health check failed for $TAG" >&2
  PREV=$(cat "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$PREV" ] && [ "$PREV" != "$TAG" ]; then
    echo ">> rolling back to $PREV"
    if redeploy "$PREV" && HEALTH_TIMEOUT=$ROLLBACK_HEALTH_TIMEOUT wait_healthy; then
      echo ">> rolled back to $PREV" >&2
    else
      echo "!! rollback also failed, needs manual handling" >&2
    fi
  else
    echo "!! no prior good tag to roll back to" >&2
  fi
  exit 1
fi
