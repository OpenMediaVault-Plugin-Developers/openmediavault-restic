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

# Configure the settings config
if ! omv_config_exists "${SERVICE_XPATH}/settings"; then
    omv_config_add_node "${SERVICE_XPATH}" "settings"
    omv_config_add_key "${SERVICE_XPATH}/settings" "cachedir" "/var/cache/restic"
fi

# Configure the repos config
if ! omv_config_exists "${SERVICE_XPATH}/repos"; then
    omv_config_add_node "${SERVICE_XPATH}" "repos" ""
fi

# Configure the snapsots config
if ! omv_config_exists "${SERVICE_XPATH}/snapshots"; then
    omv_config_add_node "${SERVICE_XPATH}" "snapshots" ""
fi

# Configure the environment variables config
if ! omv_config_exists "${SERVICE_XPATH}/envvars"; then
    omv_config_add_node "${SERVICE_XPATH}" "envvars" ""
fi

exit 0
