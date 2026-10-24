#!/bin/sh
#
# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2013-2026 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

set -e

. /usr/share/openmediavault/scripts/helper-functions

SERVICE_XPATH_NAME="restic"
SERVICE_XPATH="/config/services/${SERVICE_XPATH_NAME}"

if ! omv_config_exists "${SERVICE_XPATH}"; then
    omv_config_add_node "/config/services" "${SERVICE_XPATH_NAME}"
fi

# Add each "key:default" pair below the given XPath unless it already exists.
# Runs on every configure, so keys added during development reach existing
# installs without a migration.
add_missing_keys() {
    xpath=$1
    shift
    for kv in "$@"; do
        key="${kv%%:*}"
        if ! omv_config_exists "${xpath}/${key}"; then
            omv_config_add_key "${xpath}" "${key}" "${kv#*:}"
        fi
    done
}

# Configure the settings config
if ! omv_config_exists "${SERVICE_XPATH}/settings"; then
    omv_config_add_node "${SERVICE_XPATH}" "settings"
fi
add_missing_keys "${SERVICE_XPATH}/settings" \
    "cachedir:/var/cache/restic" "exclude:" "excludecaches:0"

# Configure the repos config
if ! omv_config_exists "${SERVICE_XPATH}/repos"; then
    omv_config_add_node "${SERVICE_XPATH}" "repos" ""
fi

# Backend, scheduled check and retention options on existing repositories. omv_config_add_key edits
# every node matching the XPath, so this only touches repos lacking the key.
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(connections)]" "connections" "0"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(options)]" "options" ""
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(checkschedule)]" "checkschedule" "disabled"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(checkreaddata)]" "checkreaddata" ""
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(checkemail)]" "checkemail" "onerror"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetschedule)]" "forgetschedule" "disabled"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetkeeplast)]" "forgetkeeplast" "0"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetkeepdaily)]" "forgetkeepdaily" "7"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetkeepweekly)]" "forgetkeepweekly" "4"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetkeepmonthly)]" "forgetkeepmonthly" "12"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetkeepyearly)]" "forgetkeepyearly" "0"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgethost)]" "forgethost" ""
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgettag)]" "forgettag" ""
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetprune)]" "forgetprune" "1"
omv_config_add_key "${SERVICE_XPATH}/repos/repo[not(forgetemail)]" "forgetemail" "onerror"

# Configure the snapsots config
if ! omv_config_exists "${SERVICE_XPATH}/snapshots"; then
    omv_config_add_node "${SERVICE_XPATH}" "snapshots" ""
fi

# Configure the restore tests config
if ! omv_config_exists "${SERVICE_XPATH}/restoretests"; then
    omv_config_add_node "${SERVICE_XPATH}" "restoretests" ""
fi

# Pre/post hook scripts on existing backup jobs and restore tests.
for job in snapshots/snapshot restoretests/restoretest; do
    omv_config_add_key "${SERVICE_XPATH}/${job}[not(prescript)]" "prescript" ""
    omv_config_add_key "${SERVICE_XPATH}/${job}[not(postscript)]" "postscript" ""
done

# Configure the REST server config
if ! omv_config_exists "${SERVICE_XPATH}/restserver"; then
    omv_config_add_node "${SERVICE_XPATH}" "restserver"
fi
add_missing_keys "${SERVICE_XPATH}/restserver" \
    "enable:0" "sharedfolderref:" "port:8000" "auth:1" "privaterepos:0" \
    "appendonly:0" "tls:0" "sslcertificateref:"

# Configure the REST server users config
if ! omv_config_exists "${SERVICE_XPATH}/restusers"; then
    omv_config_add_node "${SERVICE_XPATH}" "restusers" ""
fi

# Configure the environment variables config
if ! omv_config_exists "${SERVICE_XPATH}/envvars"; then
    omv_config_add_node "${SERVICE_XPATH}" "envvars" ""
fi

exit 0
