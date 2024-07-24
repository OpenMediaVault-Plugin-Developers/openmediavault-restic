# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2024 OpenMediaVault Plugin Developers
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

{% set config = salt['omv_conf.get']('conf.service.restic') %}
{% set envVarDir = '/etc/restic' %}
{% set envVarPrefix = 'restic-envvar-' %}
{% set logFile = '/var/log/restic.log' %}
{% set scriptsDir = '/var/lib/openmediavault/restic' %}
{% set scriptPrefix = 'restic-' %}

# Ensure that we have /etc/restic available and with the right permissions
configure_restic_envvar_dir:
  file.directory:
    - name: "{{ envVarDir }}"
    - user: root
    - group: root
    - mode: 700

# Remove pre-existing environment variable files
remove_envvar_files:
  module.run:
    - file.find:
        - path: "{{ envVarDir }}"
        - iname: "{{ envVarPrefix }}*"
        - delete: "f"

# Create an environment variable file for each repository.
# This will show up in the filesystem as e.g.:
# /etc/restic/restic-envvar-b5bad571-e5d4-4f98-84ec-3a35c2bf97ba
{% for repo in config.repos.repo %}
{% set envVarFile = envVarDir ~ '/' ~ envVarPrefix ~ repo.uuid %}

configure_restic_envvar_{{ repo.uuid }}:
  file.managed:
    - name: "{{ envVarFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-restic_envvar.j2
    - context:
        config: {{ config | json }}
        repouuid: {{ repo.uuid }}
    - template: jinja
    - user: root
    - group: root
    - mode: 600
{% endfor %}

# Create an environment variable file which will be used for all repositories.
# This will show up in the filesystem as e.g.:
# /etc/restic/restic-envvar-shared
{% set envVarFile = envVarDir ~ '/' ~ envVarPrefix ~ 'shared' %}
configure_restic_envvar_shared:
  file.managed:
    - name: "{{ envVarFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-restic_envvar.j2
    - context:
        config: {{ config | json }}
        repouuid: "shared"
    - template: jinja
    - user: root
    - group: root
    - mode: 600
