# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2026 openmediavault plugin developers
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

{# -----------------------------------------------------------------------
   Optional restic REST server, serving a shared folder to remote restic
   clients. The package is only installed once the server is enabled, and
   the packaged systemd unit is customised through a drop-in rather than by
   editing the package's conffiles.
   ----------------------------------------------------------------------- #}

{% set config = salt['omv_conf.get']('conf.service.restic.restserver') %}
{% set users = salt['omv_conf.get']('conf.service.restic.restuser') %}
{% set serviceName = 'restic-rest-server' %}
{% set htpasswdFile = '/etc/restic/rest-server.htpasswd' %}
{% set dropinDir = '/etc/systemd/system/' ~ serviceName ~ '.service.d' %}
{% set dropinFile = dropinDir ~ '/openmediavault.conf' %}
{% set ssl_cert_dir = salt['pillar.get']('default:OMV_SSL_CERTIFICATE_DIR', '/etc/ssl') %}
{% set ssl_cert_prefix = salt['pillar.get']('default:OMV_SSL_CERTIFICATE_PREFIX', 'openmediavault-') %}

{% if config.enable | to_bool and config.sharedfolderref %}

{% set dataPath = salt['omv_conf.get_sharedfolder_path'](config.sharedfolderref) %}

install_restic_rest_server:
  pkg.installed:
    - name: {{ serviceName }}

configure_restic_rest_server_htpasswd:
  file.managed:
    - name: "{{ htpasswdFile }}"
    - source:
      - salt://{{ tpldir }}/files/rest-server.htpasswd.j2
    - context:
        users: {{ users | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: True

configure_restic_rest_server_dropin:
  file.managed:
    - name: "{{ dropinFile }}"
    - source:
      - salt://{{ tpldir }}/files/rest-server-dropin.conf.j2
    - context:
        config: {{ config | json }}
        datapath: {{ dataPath | json }}
        htpasswdfile: "{{ htpasswdFile }}"
        tlscert: "{{ ssl_cert_dir ~ '/certs/' ~ ssl_cert_prefix ~ config.sslcertificateref ~ '.crt' }}"
        tlskey: "{{ ssl_cert_dir ~ '/private/' ~ ssl_cert_prefix ~ config.sslcertificateref ~ '.key' }}"
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True

reload_restic_rest_server_units:
  module.run:
    - service.systemctl_reload:
    - onchanges:
      - file: configure_restic_rest_server_dropin

start_restic_rest_server:
  service.running:
    - name: {{ serviceName }}
    - enable: True
    - require:
      - pkg: install_restic_rest_server
    - watch:
      - file: configure_restic_rest_server_htpasswd
      - file: configure_restic_rest_server_dropin
      - module: reload_restic_rest_server_units

{% else %}

{# The package is left installed; just make sure the service is off. #}
stop_restic_rest_server:
  service.dead:
    - name: {{ serviceName }}
    - enable: False

remove_restic_rest_server_dropin:
  file.absent:
    - name: "{{ dropinFile }}"

remove_restic_rest_server_htpasswd:
  file.absent:
    - name: "{{ htpasswdFile }}"

{% endif %}
