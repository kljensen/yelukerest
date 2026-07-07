#!/bin/sh

set -eu

for arg in "$@"; do
    case "$arg" in
        *deno_supervisor.mjs)
            js_dir=$(dirname "$arg")
            linereader="$js_dir/deno_linereader.mjs"
            if [ -f "$linereader" ] && ! grep -q 'rid = rid.rid' "$linereader"; then
                sed -i 's/export const readLine = async (rid) => {/export const readLine = async (rid) => {\
  if (typeof rid === "object" \&\& rid !== null \&\& "rid" in rid) {\
    rid = rid.rid;\
  }/' "$linereader"
            fi
            for js in "$js_dir"/*.js; do
                if [ -f "$js" ] && ! grep -q 'globalThis.global = globalThis' "$js"; then
                    tmp="${js}.tmp"
                    printf "%s\n" "globalThis.global = globalThis;" > "$tmp"
                    cat "$js" >> "$tmp"
                    mv "$tmp" "$js"
                fi
            done
            ;;
    esac
done

exec /usr/local/bin/deno-real "$@"
