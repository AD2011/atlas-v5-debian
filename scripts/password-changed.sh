#!/bin/sh
# Dropbear has no PAM password-expiry dialogue: require a console change first.
# ExecCondition exit 1 skips the service without marking it failed.
awk -F: '$1 == "atlas" && $2 !~ /^[!*]/ && $3 ~ /^[0-9]+$/ && $3 > 0 {ok=1} END {exit !ok}' /etc/shadow
