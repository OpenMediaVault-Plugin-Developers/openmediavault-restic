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
{% set cacheDir = config.settings.cachedir | default('') %}
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

{% if cacheDir %}
configure_restic_cache_dir:
  file.directory:
    - name: "{{ cacheDir }}"
    - user: root
    - group: root
    - mode: 700
    - makedirs: true
{% endif %}

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

# Shared environment variable file (applies to all repositories)
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
        cachedir: "{{ cacheDir }}"
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
{% set ns = namespace(cronexpr='0 0 * * *') %}
{% if job.execution == 'reboot' %}
{% set ns.cronexpr = '@reboot' %}
{% elif job.execution == 'hourly' %}
{% set ns.cronexpr = '0 * * * *' %}
{% elif job.execution == 'daily' %}
{% set ns.cronexpr = '0 0 * * *' %}
{% elif job.execution == 'weekly' %}
{% set ns.cronexpr = '0 0 * * 0' %}
{% elif job.execution == 'monthly' %}
{% set ns.cronexpr = '0 0 1 * *' %}
{% elif job.execution == 'yearly' %}
{% set ns.cronexpr = '0 0 1 1 *' %}
{% else %}
{% set _min = ('*/' ~ job.minute) if job.everynminute else job.minute %}
{% set _hour = ('*/' ~ job.hour) if job.everynhour else job.hour %}
{% set _dom = ('*/' ~ job.dayofmonth) if job.everyndayofmonth else job.dayofmonth %}
{% set ns.cronexpr = _min ~ ' ' ~ _hour ~ ' ' ~ _dom ~ ' ' ~ job.month ~ ' ' ~ job.dayofweek %}
{% endif %}
{% do cronjobs.append({
    'cronexpr':   ns.cronexpr,
    'scriptfile': scriptFile
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

{# -----------------------------------------------------------------------
   Purge stale files left over from deleted/renamed repos and jobs.
   file.tidied removes files matching the pattern that are NOT in the
   exclude list - idempotent, no delete-all-then-recreate needed.
   ----------------------------------------------------------------------- #}

{% set keep_env = [] %}
{% for repo in config.repos.repo %}
{% do keep_env.append(envVarPrefix ~ repo.uuid) %}
{% endfor %}
{% do keep_env.append(envVarPrefix ~ 'shared') %}

purge_stale_restic_envvars:
  file.tidied:
    - name: "{{ envVarDir }}"
    - matches:
      - "{{ envVarPrefix }}.*"
    - exclude:
{%- for f in keep_env %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True


{% set keep_scripts = [] %}
{% for job in config.snapshots.snapshot %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] %}
{% do keep_scripts.append(scriptPrefix ~ job.uuid ~ '.sh') %}
{% endif %}
{% endfor %}

purge_stale_restic_scripts:
  file.tidied:
    - name: "{{ scriptsDir }}"
    - matches:
      - "{{ scriptPrefix }}.*"
    - exclude:
{%- for f in keep_scripts %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True
