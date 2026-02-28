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

{% set config = salt['omv_conf.get']('conf.service.restic') %}
{% set envVarDir = '/etc/restic' %}
{% set envVarPrefix = 'restic-envvar-' %}
{% set logDir = '/var/log/restic' %}
{% set scriptsDir = '/var/lib/openmediavault/restic' %}
{% set scriptPrefix = 'restic-job-' %}
{% set cronFile = '/etc/cron.d/openmediavault-restic' %}

{# -----------------------------------------------------------------------
   Build lookup maps: uuid -> full path for shared folders and mount points
   ----------------------------------------------------------------------- #}
{% set mntents = {} %}
{% for m in salt['omv_conf.get']('conf.system.filesystem.mountpoint') %}
{% do mntents.update({m.uuid: m.dir}) %}
{% endfor %}

{% set sfolders = {} %}
{% for sf in salt['omv_conf.get']('conf.system.sharedfolder') %}
{% if sf.mntentref in mntents %}
{% set full_path = mntents[sf.mntentref].rstrip('/') + '/' + sf.reldirpath.lstrip('/') %}
{% else %}
{% set full_path = '/' + sf.reldirpath.lstrip('/') %}
{% endif %}
{% do sfolders.update({sf.uuid: full_path.rstrip('/')}) %}
{% endfor %}

{# -----------------------------------------------------------------------
   Build a lookup map: repo uuid -> repo object
   ----------------------------------------------------------------------- #}
{% set repomap = {} %}
{% for repo in config.repos.repo %}
{% do repomap.update({repo.uuid: repo}) %}
{% endfor %}

# Ensure required directories exist

configure_restic_log_dir:
  file.directory:
    - name: "{{ logDir }}"
    - user: root
    - group: root
    - mode: 755

configure_restic_envvar_dir:
  file.directory:
    - name: "{{ envVarDir }}"
    - user: root
    - group: root
    - mode: 700

configure_restic_scripts_dir:
  file.directory:
    - name: "{{ scriptsDir }}"
    - user: root
    - group: root
    - mode: 700

# Remove pre-existing environment variable files
remove_restic_envvar_files:
  module.run:
    - file.find:
        - path: "{{ envVarDir }}"
        - iname: "{{ envVarPrefix }}*"
        - delete: "f"

# Remove pre-existing backup job scripts
remove_restic_job_scripts:
  module.run:
    - file.find:
        - path: "{{ scriptsDir }}"
        - iname: "{{ scriptPrefix }}*"
        - delete: "f"

# Create environment variable file for each repository
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

# Create shared environment variable file (applies to all repositories)
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

# Generate a backup script for each enabled backup job
{% for job in config.snapshots.snapshot %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] %}
{% if job.reporef in repomap %}
{% set repo = repomap[job.reporef] %}

{# Resolve repository path for local repos #}
{% if repo.type == 'local' %}
{% set repo_path = sfolders.get(repo.sharedfolderref, '') %}
{% else %}
{% set repo_path = '' %}
{% endif %}

{# Resolve source shared folder paths #}
{% set source_paths = [] %}
{% if job.csvsharedfolderrefs %}
{% for uuid in job.csvsharedfolderrefs.split(',') %}
{% set uuid = uuid | trim %}
{% if uuid and uuid in sfolders %}
{% do source_paths.append(sfolders[uuid]) %}
{% endif %}
{% endfor %}
{% endif %}

{% set scriptFile = scriptsDir ~ '/' ~ scriptPrefix ~ job.uuid ~ '.sh' %}

configure_restic_job_script_{{ job.uuid }}:
  file.managed:
    - name: "{{ scriptFile }}"
    - source:
      - salt://{{ tpldir }}/files/restic-job.sh.j2
    - context:
        job: {{ job | json }}
        repo: {{ repo | json }}
        repo_path: "{{ repo_path }}"
        source_paths: {{ source_paths | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: 700
{% endif %}
{% endif %}
{% endfor %}

{# Build the list of enabled cron jobs to pass to the cron template #}
{% set cronjobs = [] %}
{% for job in config.snapshots.snapshot %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] and job.reporef in repomap %}
{% set scriptFile = scriptsDir ~ '/' ~ scriptPrefix ~ job.uuid ~ '.sh' %}
{% do cronjobs.append({
    'scheduleminute':     job.scheduleminute,
    'schedulehour':       job.schedulehour,
    'scheduledayofmonth': job.scheduledayofmonth,
    'schedulemonth':      job.schedulemonth,
    'scheduledayofweek':  job.scheduledayofweek,
    'scriptfile':         scriptFile
}) %}
{% endif %}
{% endfor %}

# Generate cron file for all enabled, scheduled backup jobs
configure_restic_cron:
  file.managed:
    - name: "{{ cronFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-cron_restic.j2
    - context:
        jobs: {{ cronjobs | json }}
        logdir: "{{ logDir }}"
    - template: jinja
    - user: root
    - group: root
    - mode: 644
