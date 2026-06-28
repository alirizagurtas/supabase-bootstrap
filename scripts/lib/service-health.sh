#!/usr/bin/env bash

# Read-only HTTP probes for the CLI-managed API gateway.

supabase_service_health() {
  local workdir="$1"
  local status_json api_url service_key

  status_json=$(cd "$workdir" && supabase status -o json 2> /dev/null) || {
    printf 'supabase status JSON alınamadı\n' >&2
    return 1
  }
  api_url=$(jq -r '.API_URL // .api_url // empty' <<< "$status_json")
  service_key=$(jq -r '.SERVICE_ROLE_KEY // .service_role_key // empty' <<< "$status_json")
  [[ "$api_url" == http://* || "$api_url" == https://* ]] || {
    printf 'Supabase API_URL bulunamadı\n' >&2
    return 1
  }
  [[ -n "$service_key" ]] || {
    printf 'Supabase SERVICE_ROLE_KEY bulunamadı\n' >&2
    return 1
  }

  curl -fsS --max-time 10 "${api_url}/auth/v1/health" > /dev/null || {
    printf 'Auth health probe başarısız\n' >&2
    return 1
  }
  curl -fsS --max-time 10 \
    -H "apikey: ${service_key}" \
    -H "Authorization: Bearer ${service_key}" \
    "${api_url}/rest/v1/" > /dev/null || {
    printf 'REST health probe başarısız\n' >&2
    return 1
  }
  curl -fsS --max-time 10 "${api_url}/storage/v1/status" > /dev/null || {
    printf 'Storage health probe başarısız\n' >&2
    return 1
  }
}
