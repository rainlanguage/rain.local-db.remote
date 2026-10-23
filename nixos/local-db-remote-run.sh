set -euo pipefail

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

validate_deployment_id() {
  case "$LOCAL_DB_DEPLOYMENT_ID" in
    "")
      echo "LOCAL_DB_DEPLOYMENT_ID must not be empty" >&2
      exit 1
      ;;
    *[!a-zA-Z0-9_.-]*)
      echo "LOCAL_DB_DEPLOYMENT_ID must contain only letters, numbers, dots, underscores, and dashes" >&2
      exit 1
      ;;
  esac
}

resolve_manifest_publish_target() {
  local urls first_url

  urls="$("$cli_bin" local-db manifest-urls --settings-yaml "$settings_yaml")"
  first_url=""

  while IFS= read -r url; do
    if [ -n "$url" ]; then
      first_url="$url"
      break
    fi
  done <<<"$urls"

  if [ -z "$first_url" ]; then
    echo "Expected at least one local-db remote manifest URL" >&2
    exit 1
  fi

  manifest_url="$first_url"
  manifest_dir_url="${manifest_url%/*}"

  if [ "$manifest_dir_url" = "$manifest_url" ]; then
    echo "Manifest URL does not contain a publish directory: $manifest_url" >&2
    exit 1
  fi
}

url_host() {
  local without_scheme="$1"
  without_scheme="${without_scheme#http://}"
  without_scheme="${without_scheme#https://}"
  printf '%s\n' "${without_scheme%%/*}"
}

url_path() {
  local without_scheme="$1"
  without_scheme="${without_scheme#http://}"
  without_scheme="${without_scheme#https://}"

  case "$without_scheme" in
    */*) printf '/%s\n' "${without_scheme#*/}" ;;
    *) printf '\n' ;;
  esac
}

object_key_from_url() {
  local url="$1"
  local host path endpoint_host

  host="$(url_host "$url")"
  path="$(url_path "$url")"
  endpoint_host="$(url_host "$SPACES_ENDPOINT")"

  case "$host" in
    "$SPACES_BUCKET.$endpoint_host")
      printf '%s\n' "${path#/}"
      ;;
    "$endpoint_host")
      case "$path" in
        "/$SPACES_BUCKET/"*)
          printf '%s\n' "${path#/"$SPACES_BUCKET"/}"
          ;;
        *)
          echo "Manifest URL path is not inside bucket $SPACES_BUCKET: $url" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "Manifest URL host does not match bucket endpoint: $url" >&2
      exit 1
      ;;
  esac
}

if [ -n "${LOCAL_DB_DEPLOYMENT_ID:-}" ]; then
  validate_deployment_id
  deployment_label="deployment $LOCAL_DB_DEPLOYMENT_ID"
  deployment_root="/var/lib/local-db-remote/deployments/$LOCAL_DB_DEPLOYMENT_ID"
  cli_bin="$deployment_root/bin/rain-orderbook-cli"
  state_root="/var/lib/local-db-remote/work/$LOCAL_DB_DEPLOYMENT_ID"
else
  deployment_label="legacy deployment"
  cli_bin="/var/lib/local-db-remote/bin/rain-orderbook-cli"
  state_root="/var/lib/local-db-remote/work"
fi

out_root="$state_root/local-db"

cleanup() {
  rm -rf "$out_root"
}

trap cleanup EXIT

require_var SETTINGS_YAML_URL
require_var HYPER_RPC_API_TOKEN
require_var SPACES_ACCESS_KEY
require_var SPACES_SECRET_KEY
require_var SPACES_REGION
require_var SPACES_BUCKET
require_var SPACES_ENDPOINT

if [ ! -x "$cli_bin" ]; then
  echo "CLI binary not found at $cli_bin" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY"
export AWS_DEFAULT_REGION="$SPACES_REGION"
# The AWS CLI otherwise uses its vendored CA bundle instead of the host's.
export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

manifest_url=""
manifest_dir_url=""

mkdir -p "$state_root"

echo "Fetching settings YAML from $SETTINGS_YAML_URL"
settings_yaml="$(curl -fsSL "$SETTINGS_YAML_URL")"
resolve_manifest_publish_target
manifest_object_key="$(object_key_from_url "$manifest_url")"
publish_prefix_key="${manifest_object_key%/*}"

if [ "$publish_prefix_key" = "$manifest_object_key" ]; then
  publish_prefix_key=""
fi

echo "Running local-db sync for $deployment_label via $cli_bin"
"$cli_bin" local-db sync \
  --settings-yaml "$settings_yaml" \
  --api-token "$HYPER_RPC_API_TOKEN" \
  --release-base-url "$manifest_dir_url" \
  --out-root "$out_root" \
  --debug-status

if [ ! -d "$out_root" ]; then
  echo "Expected sync output directory at $out_root" >&2
  exit 1
fi

echo "Uploading SQL dump files"
find "$out_root" -type f -iname "*-0x*.sql.gz" | while IFS= read -r file; do
  filename="$(basename "$file")"
  if [ -n "$publish_prefix_key" ]; then
    object_key="$publish_prefix_key/$filename"
  else
    object_key="$filename"
  fi
  echo "Uploading $filename"
  aws s3 cp "$file" "s3://$SPACES_BUCKET/$object_key" \
    --endpoint-url "$SPACES_ENDPOINT" \
    --acl public-read \
    --content-type "application/gzip"
done

if [ -f "$out_root/manifest.yaml" ]; then
  echo "Uploading manifest.yaml to $manifest_url"
  aws s3 cp "$out_root/manifest.yaml" "s3://$SPACES_BUCKET/$manifest_object_key" \
    --endpoint-url "$SPACES_ENDPOINT" \
    --acl public-read \
    --content-type "text/yaml"
fi

echo "Local DB remote sync completed for $deployment_label"
