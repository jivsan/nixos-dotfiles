#!/bin/sh
# scrutiny's drive alerts to my phone: ntfy topic alerts, as the ntfy user truenas (token "scrutiny-odyn").
# scrutiny runs this for every alert (scrutiny.yaml: script:///opt/scrutiny/config/ntfy-alert.sh) and
# hands over SCRUTINY_SUBJECT, SCRUTINY_MESSAGE, SCRUTINY_DEVICE_NAME, SCRUTINY_FAILURE_TYPE and more.
# the token is in ntfy-auth.hdr next to this file (0600, one line "Authorization: Bearer tk_..."),
# and curl reads it from there, so it's never on a command line or in a log.
# lives in vault/appdata/scrutiny/config on odyn, copied there from odyn/apps/scrutiny in the repo.
set -eu
here=$(dirname "$0")
printf '%s\n\n%s\n' "${SCRUTINY_SUBJECT:-scrutiny}" "${SCRUTINY_MESSAGE:-}" |
  curl -fsS -o /dev/null --max-time 20 \
    -H @"$here/ntfy-auth.hdr" \
    -H "Title: Drive health (scrutiny)" \
    -H "Priority: high" \
    -H "Tags: floppy_disk" \
    --data-binary @- \
    https://ntfy.oryxserver.org/alerts
