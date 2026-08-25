#!/bin/sh

prompt="$*"
state_file="${SHUTTLER_ASKPASS_STATE_FILE:-}"
response_file="${SHUTTLER_ASKPASS_RESPONSE_FILE:-}"
prompt_dir="${SHUTTLER_ASKPASS_PROMPT_DIR:-/tmp}"
password_file="${SHUTTLER_ASKPASS_PASSWORD_FILE:-}"
auto_password="${SHUTTLER_ASKPASS_AUTO_PASSWORD:-0}"

count=0
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
    count="$(/bin/cat "$state_file" 2>/dev/null || /bin/echo 0)"
fi

case "$count" in
    ''|*[!0-9]*) count=0 ;;
esac

count=$((count + 1))
if [ -n "$state_file" ]; then
    /bin/echo "$count" > "$state_file"
    /bin/chmod 600 "$state_file" 2>/dev/null
fi

lower="$(printf '%s' "$prompt" | /usr/bin/tr '[:upper:]' '[:lower:]')"
if [ "$count" -eq 1 ] && [ "$auto_password" = "1" ] && [ -n "$password_file" ] && [ -f "$password_file" ]; then
    case "$lower" in
        *passcode*|*verification*|*token*|*otp*|*option*)
            ;;
        *)
            /bin/cat "$password_file"
            exit 0
            ;;
    esac
fi

if [ -z "$response_file" ]; then
    exit 1
fi

/bin/mkdir -p "$prompt_dir" 2>/dev/null
prompt_file="$prompt_dir/prompt_$$.txt"
printf '%s\n' "${prompt:-Authentication prompt}" > "$prompt_file"
/bin/chmod 600 "$prompt_file" 2>/dev/null

waited=0
maxwait=240
while [ ! -f "$response_file" ] && [ "$waited" -lt "$maxwait" ]; do
    /bin/sleep 1
    waited=$((waited + 1))
done

if [ ! -f "$response_file" ]; then
    exit 1
fi

/bin/cat "$response_file"
/bin/rm -f "$response_file"
exit 0
