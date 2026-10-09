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

include:
  - .restserver

{% set config = salt['omv_conf.get']('conf.service.restic') %}
{% set envVarDir = '/etc/restic' %}
{% set envVarPrefix = 'restic-envvar-' %}
{% set logDir = '/var/log/restic' %}
{% set cacheDir = config.settings.cachedir | default('') %}
{% set scriptsDir = '/var/lib/openmediavault/restic' %}
{% set scriptPrefix = 'restic-job-' %}
{% set restoreTestPrefix = 'restic-restoretest-' %}
{% set checkPrefix = 'restic-check-' %}
{% set forgetPrefix = 'restic-forget-' %}
{% set excludeFile = envVarDir ~ '/exclude-default' %}
{% set excludeText = config.settings.exclude | default('') | string %}
{% set excludeCaches = config.settings.excludecaches | default(false) | string | lower not in ['false', '0', 'no', 'off', ''] %}
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
    - mode: '0755'

{% if cacheDir %}
configure_restic_cache_dir:
  file.directory:
    - name: "{{ cacheDir }}"
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: true
{% endif %}

configure_restic_envvar_dir:
  file.directory:
    - name: "{{ envVarDir }}"
    - user: root
    - group: root
    - mode: '0700'

configure_restic_scripts_dir:
  file.directory:
    - name: "{{ scriptsDir }}"
    - user: root
    - group: root
    - mode: '0700'

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
    - mode: '0600'
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
    - mode: '0600'

# Default exclude patterns (Settings), passed to every backup via --exclude-file
{% if excludeText | trim %}
configure_restic_exclude_default:
  file.managed:
    - name: "{{ excludeFile }}"
    - source:
      - salt://{{ tpldir }}/files/etc-restic_exclude.j2
    - context:
        exclude: {{ excludeText | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
{% else %}
remove_restic_exclude_default:
  file.absent:
    - name: "{{ excludeFile }}"
{% endif %}

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
        hashfile: "{{ scriptsDir ~ '/hash-' ~ job.uuid }}"
        cachedir: "{{ cacheDir }}"
        excludefile: "{{ excludeFile if excludeText | trim else '' }}"
        excludecaches: {{ excludeCaches | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: '0700'
{% endif %}
{% endif %}
{% endfor %}

# Generate a script for each enabled restore test job
{% for job in config.restoretests.restoretest %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] %}
{% if job.reporef in repomap %}
{% set repo = repomap[job.reporef] %}

{# Resolve repository path for local repos #}
{% if repo.type == 'local' %}
{% set repo_path = sfolders.get(repo.sharedfolderref, '') %}
{% else %}
{% set repo_path = '' %}
{% endif %}

{# Resolve the verify restore target: a per-test subdirectory inside the
   selected shared folder, so cleanup only ever removes data we created. #}
{% set target_path = '' %}
{% if job.mode == 'verify' and job.targetref in sfolders %}
{% set target_path = sfolders[job.targetref] ~ '/' ~ restoreTestPrefix ~ job.uuid %}
{% endif %}

{% set scriptFile = scriptsDir ~ '/' ~ restoreTestPrefix ~ job.uuid ~ '.sh' %}

configure_restic_restoretest_script_{{ job.uuid }}:
  file.managed:
    - name: "{{ scriptFile }}"
    - source:
      - salt://{{ tpldir }}/files/restic-restoretest.sh.j2
    - context:
        job: {{ job | json }}
        repo: {{ repo | json }}
        repo_path: "{{ repo_path }}"
        target_path: "{{ target_path }}"
        cachedir: "{{ cacheDir }}"
    - template: jinja
    - user: root
    - group: root
    - mode: '0700'
{% endif %}
{% endif %}
{% endfor %}

# Generate a scheduled check script for each repository with checks enabled
{% for repo in config.repos.repo %}
{% if repo.checkschedule | default('disabled') != 'disabled' %}

{% if repo.type == 'local' %}
{% set repo_path = sfolders.get(repo.sharedfolderref, '') %}
{% else %}
{% set repo_path = '' %}
{% endif %}

configure_restic_check_script_{{ repo.uuid }}:
  file.managed:
    - name: "{{ scriptsDir ~ '/' ~ checkPrefix ~ repo.uuid ~ '.sh' }}"
    - source:
      - salt://{{ tpldir }}/files/restic-check.sh.j2
    - context:
        repo: {{ repo | json }}
        repo_path: "{{ repo_path }}"
        cachedir: "{{ cacheDir }}"
    - template: jinja
    - user: root
    - group: root
    - mode: '0700'
{% endif %}
{% endfor %}

# Generate a scheduled retention script for each repository with it enabled
{% for repo in config.repos.repo %}
{% if repo.forgetschedule | default('disabled') != 'disabled' %}

{% if repo.type == 'local' %}
{% set repo_path = sfolders.get(repo.sharedfolderref, '') %}
{% else %}
{% set repo_path = '' %}
{% endif %}

configure_restic_forget_script_{{ repo.uuid }}:
  file.managed:
    - name: "{{ scriptsDir ~ '/' ~ forgetPrefix ~ repo.uuid ~ '.sh' }}"
    - source:
      - salt://{{ tpldir }}/files/restic-forget.sh.j2
    - context:
        repo: {{ repo | json }}
        repo_path: "{{ repo_path }}"
        cachedir: "{{ cacheDir }}"
    - template: jinja
    - user: root
    - group: root
    - mode: '0700'
{% endif %}
{% endfor %}

{# One field of a "certain date" schedule. "Every N" only applies to a single
   positive number: `*/0`, `*/*` and `*/1,2` are not valid cron fields. Must
   match buildCronSchedule() in the RPC service. #}
{% macro cron_field(value, everyn) -%}
{%- set v = value | string | trim -%}
{%- if everyn | string | lower not in ['false', '0', 'no', 'off', ''] and v.isdigit() and v | int > 0 -%}
*/{{ v }}
{%- else -%}
{{ v }}
{%- endif -%}
{%- endmacro %}

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
{% set ns.cronexpr = cron_field(job.minute, job.everynminute) ~ ' ' ~ cron_field(job.hour, job.everynhour) ~ ' ' ~ cron_field(job.dayofmonth, job.everyndayofmonth) ~ ' ' ~ job.month ~ ' ' ~ job.dayofweek %}
{% endif %}
{% do cronjobs.append({
    'cronexpr':   ns.cronexpr,
    'scriptfile': scriptFile
}) %}
{% endif %}
{% endfor %}

{# Append cron entries for enabled restore test jobs #}
{% for job in config.restoretests.restoretest %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] and job.reporef in repomap %}
{% set scriptFile = scriptsDir ~ '/' ~ restoreTestPrefix ~ job.uuid ~ '.sh' %}
{% set ns = namespace(cronexpr='0 0 * * 0') %}
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
{% set ns.cronexpr = cron_field(job.minute, job.everynminute) ~ ' ' ~ cron_field(job.hour, job.everynhour) ~ ' ' ~ cron_field(job.dayofmonth, job.everyndayofmonth) ~ ' ' ~ job.month ~ ' ' ~ job.dayofweek %}
{% endif %}
{% do cronjobs.append({
    'cronexpr':   ns.cronexpr,
    'scriptfile': scriptFile
}) %}
{% endif %}
{% endfor %}

{# Append cron entries for scheduled repository checks. These run at 03:00 so
   they normally do not overlap the default midnight backup schedule. #}
{% set checkCron = {'daily': '0 3 * * *', 'weekly': '0 3 * * 0', 'monthly': '0 3 1 * *'} %}
{% for repo in config.repos.repo %}
{% if repo.checkschedule | default('disabled') in checkCron %}
{% do cronjobs.append({
    'cronexpr':   checkCron[repo.checkschedule],
    'scriptfile': scriptsDir ~ '/' ~ checkPrefix ~ repo.uuid ~ '.sh'
}) %}
{% endif %}
{% endfor %}

{# Scheduled retention runs at 02:00, an hour before the check, so the check
   normally sees the pruned repository. Both also share a per-repo lock. #}
{% set forgetCron = {'daily': '0 2 * * *', 'weekly': '0 2 * * 0', 'monthly': '0 2 1 * *'} %}
{% for repo in config.repos.repo %}
{% if repo.forgetschedule | default('disabled') in forgetCron %}
{% do cronjobs.append({
    'cronexpr':   forgetCron[repo.forgetschedule],
    'scriptfile': scriptsDir ~ '/' ~ forgetPrefix ~ repo.uuid ~ '.sh'
}) %}
{% endif %}
{% endfor %}

# Generate cron file for all enabled, scheduled backup, restore test and check jobs
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
    - mode: '0644'

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


{% set keep_restoretest_scripts = [] %}
{% for job in config.restoretests.restoretest %}
{% if job.enable | string | lower not in ['false', '0', 'no', 'off'] %}
{% do keep_restoretest_scripts.append(restoreTestPrefix ~ job.uuid ~ '.sh') %}
{% endif %}
{% endfor %}

purge_stale_restic_restoretest_scripts:
  file.tidied:
    - name: "{{ scriptsDir }}"
    - matches:
      - "{{ restoreTestPrefix }}.*"
    - exclude:
{%- for f in keep_restoretest_scripts %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True


{% set keep_check_scripts = [] %}
{% for repo in config.repos.repo %}
{% if repo.checkschedule | default('disabled') != 'disabled' %}
{% do keep_check_scripts.append(checkPrefix ~ repo.uuid ~ '.sh') %}
{% endif %}
{% endfor %}

purge_stale_restic_check_scripts:
  file.tidied:
    - name: "{{ scriptsDir }}"
    - matches:
      - "{{ checkPrefix }}.*"
    - exclude:
{%- for f in keep_check_scripts %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True


{% set keep_forget_scripts = [] %}
{% for repo in config.repos.repo %}
{% if repo.forgetschedule | default('disabled') != 'disabled' %}
{% do keep_forget_scripts.append(forgetPrefix ~ repo.uuid ~ '.sh') %}
{% endif %}
{% endfor %}

purge_stale_restic_forget_scripts:
  file.tidied:
    - name: "{{ scriptsDir }}"
    - matches:
      - "{{ forgetPrefix }}.*"
    - exclude:
{%- for f in keep_forget_scripts %}
      - "{{ f }}"
{%- endfor %}
    - rmdirs: False
    - rmlinks: True
