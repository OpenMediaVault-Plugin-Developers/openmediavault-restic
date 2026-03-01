<?php
/**
 * Copyright (C) 2013-2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

class OMVRpcServiceRestic extends \OMV\Rpc\ServiceAbstract
{
    private $getProgram = '/usr/bin/restic';
    private $envFile = '/etc/restic/restic-envvar-';

    public function getName()
    {
        return "Restic";
    }

    public function initialize()
    {
        // Settings
        $this->registerMethod("getSettings");
        $this->registerMethod("setSettings");

        // Repositories
        $this->registerMethod("getRepoList");
        $this->registerMethod("enumerateRepoCandidates");
        $this->registerMethod("getRepo");
        $this->registerMethod("setRepo");
        $this->registerMethod("deleteRepo");
        $this->registerMethod("checkRepo");
        $this->registerMethod("pruneRepo");
        $this->registerMethod("getRepoStats");
        $this->registerMethod("getRepoSnapshotList");

        // Backup jobs (referred to as "snapshots" for backward compatibility)
        $this->registerMethod("getSnapshotList");
        $this->registerMethod("createSnapshot");
        $this->registerMethod("getSnapshot");
        $this->registerMethod("setSnapshot");
        $this->registerMethod("deleteSnapshot");
        $this->registerMethod("runSnapshot");

        // Restore
        $this->registerMethod("restoreSnapshot");

        // Environment variables
        $this->registerMethod('getEnvVarList');
        $this->registerMethod('getEnvVar');
        $this->registerMethod('setEnvVar');
        $this->registerMethod('deleteEnvVar');
    }

    // =========================================================================
    // Settings
    // =========================================================================

    public function getSettings($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.restic.settings");
        return $object->getAssoc();
    }

    public function setSettings($params, $context)
    {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.restic.setsettings');
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.restic.settings");
        $object->setFlatAssoc([
            "enable"   => $params['enable'],
            "cachedir" => $params['cachedir'],
        ]);
        $db->set($object);
        return $object->getAssoc();
    }

    // =========================================================================
    // Helper: configure environment for a repository
    // =========================================================================

    /**
     * Set RESTIC_PASSWORD and RESTIC_REPOSITORY (plus backend credentials)
     * as environment variables on a Process object. Does NOT use escapeshellarg
     * because setEnv passes values directly to the process environment.
     */
    private function buildRepoEnv($repo, $context, &$cmd)
    {
        $type = $repo->get('type');

        // Password is always required
        $cmd->setEnv("RESTIC_PASSWORD", $repo->get('passphrase'));

        switch ($type) {
            case 'local':
                $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                    'uuid' => $repo->get('sharedfolderref')
                ], $context);
                $cmd->setEnv("RESTIC_REPOSITORY", $path);
                break;

            case 's3':
                $cmd->setEnv("RESTIC_REPOSITORY", 's3:' . $repo->get('uri'));
                $cmd->setEnv("AWS_ACCESS_KEY_ID", $repo->get('accesskey'));
                $cmd->setEnv("AWS_SECRET_ACCESS_KEY", $repo->get('secretkey'));
                break;

            case 'b2':
                $cmd->setEnv("RESTIC_REPOSITORY", 'b2:' . $repo->get('uri'));
                $cmd->setEnv("B2_ACCOUNT_ID", $repo->get('accesskey'));
                $cmd->setEnv("B2_ACCOUNT_KEY", $repo->get('secretkey'));
                break;

            case 'sftp':
                $cmd->setEnv("RESTIC_REPOSITORY", 'sftp:' . $repo->get('uri'));
                break;

            case 'rest':
                $cmd->setEnv("RESTIC_REPOSITORY", 'rest:' . $repo->get('uri'));
                break;

            default:
                // Custom/other: use URI as-is
                $cmd->setEnv("RESTIC_REPOSITORY", $repo->get('uri'));
                break;
        }

        $settings = \OMV\Config\Database::getInstance()->get("conf.service.restic.settings");
        $cacheDir = $settings->get("cachedir");
        if (!empty($cacheDir)) {
            $cmd->setEnv("RESTIC_CACHE_DIR", $cacheDir);
        }
    }

    /**
     * Apply a retention policy via `restic forget --prune`.
     * Called after a successful backup. Only runs if any keep-* value > 0.
     */
    private function applyRetentionPolicy($params, $repo, $context, $bgOutputFilename)
    {
        $keepLast    = isset($params['keeplast'])    ? intval($params['keeplast'])    : 0;
        $keepDaily   = isset($params['keepdaily'])   ? intval($params['keepdaily'])   : 0;
        $keepWeekly  = isset($params['keepweekly'])  ? intval($params['keepweekly'])  : 0;
        $keepMonthly = isset($params['keepmonthly']) ? intval($params['keepmonthly']) : 0;
        $keepYearly  = isset($params['keepyearly'])  ? intval($params['keepyearly'])  : 0;

        if ($keepLast + $keepDaily + $keepWeekly + $keepMonthly + $keepYearly === 0) {
            return;
        }

        $forgetArgs = [$this->getProgram, 'forget', '--prune'];
        if ($keepLast    > 0) $forgetArgs[] = '--keep-last '    . $keepLast;
        if ($keepDaily   > 0) $forgetArgs[] = '--keep-daily '   . $keepDaily;
        if ($keepWeekly  > 0) $forgetArgs[] = '--keep-weekly '  . $keepWeekly;
        if ($keepMonthly > 0) $forgetArgs[] = '--keep-monthly ' . $keepMonthly;
        if ($keepYearly  > 0) $forgetArgs[] = '--keep-yearly '  . $keepYearly;

        // Scope to this job's source paths so retention does not affect
        // snapshots from other backup jobs sharing the same repository.
        foreach ($params['sharedfolderrefs'] as $uuid) {
            try {
                $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $uuid], $context);
                $forgetArgs[] = '--path ' . escapeshellarg($sfpath);
            } catch (\Exception $e) {
                // skip unresolvable paths
            }
        }

        $forgetCmd = new \OMV\System\Process($forgetArgs);
        $this->buildRepoEnv($repo, $context, $forgetCmd);
        $forgetCmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
        $forgetCmd->setEnvFromFile($this->envFile . 'shared');
        $forgetCmd->setRedirect2to1();
        $forgetCmdLine = $forgetCmd->getCommandLine();
        $this->writeBgProcOutput($bgOutputFilename, sprintf(
            "\n\nApplying retention policy: %s\n\n",
            $forgetCmdLine
        ));
        $this->exec($forgetCmdLine, $output, $bgOutputFilename);
    }

    // =========================================================================
    // Repositories
    // =========================================================================

    public function getRepoList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.getlist');

        $db = \OMV\Config\Database::getInstance();
        $repos = $db->get('conf.service.restic.repo');
        $snapshots = $db->get('conf.service.restic.snapshot');

        $objectsAssoc = [];
        foreach ($repos as $repok => &$repov) {
            $repov->add('sharedfoldername', 'string', gettext("n/a"));
            if ($repov->get('type') === 'local' && !empty($repov->get('sharedfolderref'))) {
                try {
                    $sfObject = $db->get('conf.system.sharedfolder', $repov->get('sharedfolderref'));
                    $repov->set('sharedfoldername', $sfObject->get('name'));
                } catch (\Exception $e) {}
            }
            $snapshotCount = 0;
            foreach ($snapshots as $snapshotv) {
                if ($snapshotv->get('reporef') == $repov->get('uuid')) {
                    $snapshotCount++;
                }
            }
            $repov->add('snapshotCount', 'integer', $snapshotCount);
            $objectsAssoc[] = $repov->getAssoc();
        }
        return $this->applyFilter(
            $objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function enumerateRepoCandidates($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        $repos = $db->getAssoc('conf.service.restic.repo');
        if (!empty($params['shared'])) {
            $repos[] = ['name' => 'All Repositories', 'uuid' => 'shared'];
        }
        return $repos;
    }

    public function getRepo($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.restic.repo', $params['uuid']);
    }

    public function setRepo($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.restic.setrepo');

        $type = $params['type'];
        $params['name'] = str_replace(' ', '_', $params['name']);

        $repo = new \OMV\Config\ConfigObject('conf.service.restic.repo');
        $db = \OMV\Config\Database::getInstance();
        $skipinit = $params['skipinit'];
        unset($params['skipinit']);
        $repo->setAssoc($params);

        $isNew = $repo->isNew();
        if ($isNew) {
            $db->assertIsUnique($repo, 'name');
            // Only assert unique shared folder for local repos
            if ($type === 'local') {
                $db->assertIsUnique($repo, 'sharedfolderref');
            }
        }

        // Initialise unless skipped
        if (!$skipinit) {
            $cmdArgs = [$this->getProgram, 'init'];
            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            if (!$isNew) {
                $cmd->setEnvFromFile($this->envFile . $params['uuid']);
            }
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            $cmd->execute($output, $exitStatus);
            if (0 !== $exitStatus) {
                throw new \OMV\ExecException($cmdLine, $output);
            }
        }

        $db->set($repo);
        return $repo->getAssoc();
    }

    public function deleteRepo($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();

        // Ensure no backup jobs reference this repo
        $snapshots = $db->get('conf.service.restic.snapshot');
        foreach ($snapshots as $snapshot) {
            if ($snapshot->get('reporef') == $params['uuid']) {
                throw new \OMV\Exception(gettext(
                    "Repository is in use. Please delete the backup jobs associated with this repository first."
                ));
            }
        }

        $repo = $db->get('conf.service.restic.repo', $params['uuid']);

        // For local repos, remove the restic data files from the shared folder
        if ($repo->get('type') === 'local' && !empty($repo->get('sharedfolderref'))) {
            try {
                $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                    'uuid' => $repo->get('sharedfolderref')
                ], $context);
                $resticItems = ["config", "data", "index", "keys", "locks", "snapshots"];
                foreach ($resticItems as $item) {
                    $itemPath = $path . "/" . $item;
                    if (file_exists($itemPath)) {
                        $cmd = new \OMV\System\Process(['rm', '-rf', $itemPath]);
                        $cmd->setQuiet(true);
                        $cmd->execute();
                    }
                }
            } catch (\Exception $e) {
                // Ignore path resolution errors - repo may have been moved
            }
        }

        $db->delete($repo);
        return $repo->getAssoc();
    }

    public function checkRepo($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['uuid']);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo) {
            $cmdArgs = [$this->getProgram, 'check'];
            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            $this->writeBgProcOutput($bgOutputFilename, sprintf("Command: %s\n\n", $cmdLine));
            $this->exec($cmdLine, $output, $bgOutputFilename);
            return $output;
        });
    }

    public function pruneRepo($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['uuid']);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo) {
            $cmdArgs = [$this->getProgram, 'prune'];
            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            $this->writeBgProcOutput($bgOutputFilename, sprintf("Command: %s\n\n", $cmdLine));
            $this->exec($cmdLine, $output, $bgOutputFilename);
            return $output;
        });
    }

    public function getRepoStats($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['uuid']);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo) {
            $cmdArgs = [$this->getProgram, 'stats'];
            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            $this->writeBgProcOutput($bgOutputFilename, sprintf("Command: %s\n\n", $cmdLine));
            $this->exec($cmdLine, $output, $bgOutputFilename);
            return $output;
        });
    }

    /**
     * List actual restic snapshots stored in the repository (not OMV backup job configs).
     */
    public function getRepoSnapshotList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);

        $reporef = $params['reporef'] ?? null;
        if (empty($reporef)) {
            throw new \OMV\Exception(gettext("A repository must be specified."));
        }

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $reporef);

        $cmdArgs = [$this->getProgram, 'snapshots', '--json'];
        $cmd = new \OMV\System\Process($cmdArgs);
        $this->buildRepoEnv($repo, $context, $cmd);
        $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
        $cmd->setEnvFromFile($this->envFile . 'shared');
        // Do NOT redirect stderr to stdout — we only want the clean JSON on stdout.
        $cmd->setQuiet(true);
        $cmd->execute($output, $exitStatus);

        $snapshots = [];
        if ($exitStatus === 0 && !empty($output)) {
            $raw = implode('', $output);
            // Find the start of the JSON array in case any preamble text was emitted.
            $jsonStart = strpos($raw, '[');
            if ($jsonStart !== false) {
                $raw = substr($raw, $jsonStart);
            }
            $parsed = json_decode($raw, true);
            if (is_array($parsed)) {
                $snapshots = $parsed;
            }
        }

        // Normalise for datatable: ensure required fields exist
        foreach ($snapshots as &$s) {
            $s['id_short']  = isset($s['id']) ? substr($s['id'], 0, 8) : '';
            $s['paths_str'] = isset($s['paths'])   ? implode(', ', $s['paths'])   : '';
            $s['tags_str']  = isset($s['tags'])     ? implode(', ', $s['tags'])    : '';
            $s['hostname']  = $s['hostname'] ?? '';
            $s['username']  = $s['username'] ?? '';
            // Reformat ISO timestamp for readability
            if (!empty($s['time'])) {
                try {
                    $dt = new \DateTime($s['time']);
                    $s['time_formatted'] = $dt->format('Y-m-d H:i:s');
                } catch (\Exception $e) {
                    $s['time_formatted'] = $s['time'];
                }
            } else {
                $s['time_formatted'] = '';
            }
        }
        unset($s);

        // Apply standard list filtering / pagination
        $start      = $params['start']     ?? 0;
        $limit      = $params['limit']     ?? -1;
        $sortfield  = $params['sortfield'] ?? 'time';
        $sortdir    = $params['sortdir']   ?? 'desc';

        return $this->applyFilter($snapshots, $start, $limit, $sortfield, $sortdir);
    }

    // =========================================================================
    // Backup Jobs (called "Snapshots" for backward compatibility)
    // =========================================================================

    public function getSnapshotList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.getlist');

        $db = \OMV\Config\Database::getInstance();
        $snapshots = $db->get('conf.service.restic.snapshot');

        $snapshotsAssoc = [];
        foreach ($snapshots as &$snapshotv) {
            // Add repo name
            try {
                $repo = $db->get('conf.service.restic.repo', $snapshotv->get('reporef'));
                $snapshotv->add('reponame', 'string', $repo->get('name'));
            } catch (\Exception $e) {
                $snapshotv->add('reponame', 'string', gettext('n/a'));
            }

            // Resolve source shared folder names
            $sharedfoldernames = '';
            $csvRefs = $snapshotv->get('csvsharedfolderrefs');
            $uuids = array_filter(array_map('trim', explode(',', $csvRefs)));
            foreach ($uuids as $i => $uuid) {
                try {
                    $sharedfolder = $db->get('conf.system.sharedfolder', $uuid);
                    $sharedfoldernames .= ($i > 0 ? ', ' : '') . $sharedfolder->get('name');
                } catch (\Exception $e) {}
            }
            $snapshotv->add('sourcename', 'string', $sharedfoldernames);

            $snapshotAssoc = $snapshotv->getAssoc();
            // Override hash with flat-file value if present (avoids config DB writes on backup).
            $hashFile = '/var/lib/openmediavault/restic/hash-' . $snapshotAssoc['uuid'];
            if (file_exists($hashFile)) {
                $snapshotAssoc['hash'] = trim(file_get_contents($hashFile));
            }
            // Build a cron expression string for display (fed to cron2human in the UI).
            switch ($snapshotAssoc['execution'] ?? 'daily') {
                case 'hourly':  $snapshotAssoc['schedule'] = '0 * * * *';   break;
                case 'daily':   $snapshotAssoc['schedule'] = '0 0 * * *';   break;
                case 'weekly':  $snapshotAssoc['schedule'] = '0 0 * * 0';   break;
                case 'monthly': $snapshotAssoc['schedule'] = '0 0 1 * *';   break;
                case 'yearly':  $snapshotAssoc['schedule'] = '0 0 1 1 *';   break;
                case 'reboot':  $snapshotAssoc['schedule'] = '@reboot';      break;
                default: // exactly
                    $min = ($snapshotAssoc['everynminute']     ? '*/' : '') . $snapshotAssoc['minute'];
                    $hr  = ($snapshotAssoc['everynhour']       ? '*/' : '') . $snapshotAssoc['hour'];
                    $dom = ($snapshotAssoc['everyndayofmonth'] ? '*/' : '') . $snapshotAssoc['dayofmonth'];
                    $snapshotAssoc['schedule'] = "$min $hr $dom {$snapshotAssoc['month']} {$snapshotAssoc['dayofweek']}";
                    break;
            }
            $snapshotsAssoc[] = $snapshotAssoc;
        }
        unset($snapshotv);

        return $this->applyFilter(
            $snapshotsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function getSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        $obj = $db->getAssoc('conf.service.restic.snapshot', $params['uuid']);
        // Convert CSV back to array so the multi-select form field populates correctly
        $obj['sharedfolderrefs'] = array_values(array_filter(array_map('trim', explode(',', $obj['csvsharedfolderrefs'] ?? ''))));
        // Convert comma-separated schedule strings to arrays for the multi-select fields
        foreach (['minute', 'hour', 'dayofmonth', 'month', 'dayofweek'] as $field) {
            $obj[$field] = array_values(array_filter(array_map('trim', explode(',', $obj[$field] ?? '*'))));
        }
        return $obj;
    }

    public function setSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.restic.setsnapshot');

        // Convert sharedfolderrefs array → CSV string for storage
        $csvRefs = '';
        foreach ($params['sharedfolderrefs'] as $i => $uuid) {
            $csvRefs .= ($i > 0 ? ', ' : '') . $uuid;
        }
        unset($params['sharedfolderrefs']);
        $params['csvsharedfolderrefs'] = $csvRefs;

        // Convert schedule arrays to comma-separated strings for storage
        foreach (['minute', 'hour', 'dayofmonth', 'month', 'dayofweek'] as $field) {
            if (is_array($params[$field])) {
                $params[$field] = implode(',', $params[$field]);
            }
        }

        // Apply default values for optional fields that may be missing
        $params['enable']    = $params['enable'] ?? true;
        $params['name']      = $params['name']   ?? '';
        $params['execution'] = $params['execution'] ?? 'daily';
        $params['keeplast']   = isset($params['keeplast'])    ? intval($params['keeplast'])    : 0;
        $params['keepdaily']  = isset($params['keepdaily'])   ? intval($params['keepdaily'])   : 7;
        $params['keepweekly'] = isset($params['keepweekly'])  ? intval($params['keepweekly'])  : 4;
        $params['keepmonthly']= isset($params['keepmonthly']) ? intval($params['keepmonthly']) : 12;
        $params['keepyearly'] = isset($params['keepyearly'])  ? intval($params['keepyearly'])  : 0;

        $db = \OMV\Config\Database::getInstance();
        $snapshot = new \OMV\Config\ConfigObject('conf.service.restic.snapshot');
        $snapshot->setAssoc($params);
        $db->set($snapshot);
        return $snapshot->getAssoc();
    }

    public function createSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['reporef']);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo) {
            $cmdArgs = [$this->getProgram, 'backup', '--verbose'];

            // Tags (ignore empty strings)
            $tags = array_filter(array_map('trim', explode(',', $params['tags'] ?? '')));
            foreach ($tags as $tag) {
                $cmdArgs[] = '--tag ' . escapeshellarg($tag);
            }

            // Excludes
            $excludes = array_filter(array_map('trim', explode(',', $params['exclude'] ?? '')));
            foreach ($excludes as $excl) {
                $cmdArgs[] = '--exclude ' . escapeshellarg($excl);
            }

            // Source paths
            foreach ($params['sharedfolderrefs'] as $uuid) {
                $sfpath = \OMV\Rpc\Rpc::call("ShareMgmt", "getPath", ["uuid" => $uuid], $context);
                $cmdArgs[] = escapeshellarg($sfpath);
            }

            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();

            $this->writeBgProcOutput($bgOutputFilename, sprintf("Command: %s\n\n", $cmdLine));
            $this->exec($cmdLine, $output, $bgOutputFilename);

            // Extract the snapshot hash from the output
            preg_match('/snapshot (\w+) saved/', file_get_contents($bgOutputFilename), $matches);
            $hash = isset($matches[1]) ? $matches[1] : '';

            // Persist the hash to a flat file (not the config DB) so we avoid
            // triggering an "Apply changes" notification on every backup run.
            if (!empty($hash) && !empty($params['uuid'])) {
                $hashDir = '/var/lib/openmediavault/restic';
                if (!is_dir($hashDir)) {
                    mkdir($hashDir, 0750, true);
                }
                file_put_contents($hashDir . '/hash-' . $params['uuid'], $hash);
            }

            // Apply retention policy if configured
            $this->applyRetentionPolicy($params, $repo, $context, $bgOutputFilename);

            return $output;
        });
    }

    /**
     * Manually trigger an existing backup job by UUID.
     */
    public function runSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();
        $snapshot = $db->get('conf.service.restic.snapshot', $params['uuid']);

        // Convert CSV refs back to array for createSnapshot
        $csvRefs = $snapshot->get('csvsharedfolderrefs');
        $refs = array_filter(array_map('trim', explode(',', $csvRefs)));

        $createParams = $snapshot->getAssoc();
        $createParams['sharedfolderrefs'] = array_values($refs);
        unset($createParams['csvsharedfolderrefs']);

        return $this->callMethod('createSnapshot', $createParams, $context);
    }

    public function deleteSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $db = \OMV\Config\Database::getInstance();
        $snapshot = $db->get('conf.service.restic.snapshot', $params['uuid']);
        $repo = $db->get('conf.service.restic.repo', $snapshot->get('reporef'));

        // Forget the specific snapshot hash in the restic repo (if one was ever created).
        // Check flat file first (written by createSnapshot), fall back to config field.
        $hashFile = '/var/lib/openmediavault/restic/hash-' . $snapshot->get('uuid');
        $hash = file_exists($hashFile) ? trim(file_get_contents($hashFile)) : $snapshot->get('hash');
        if (!empty($hash)) {
            $cmdArgs = [$this->getProgram, 'forget', '--prune', $hash];
            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $snapshot->get('reporef'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setQuiet(true);
            $cmd->execute();
        }
        @unlink($hashFile);

        $db->delete($snapshot);
        return $snapshot->getAssoc();
    }

    /**
     * Restore a restic snapshot to a target shared folder.
     */
    public function restoreSnapshot($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.restic.restoresnapshot');

        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['reporef']);

        $targetPath = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $params['targetref']
        ], $context);

        return $this->execBgProc(function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo, $targetPath) {
            $cmdArgs = [
                $this->getProgram,
                'restore',
                escapeshellarg($params['snapshotid']),
                '--target',
                escapeshellarg($targetPath)
            ];

            // Optional path filter within the snapshot
            if (!empty($params['includepath'])) {
                $cmdArgs[] = '--include ' . escapeshellarg($params['includepath']);
            }

            $cmd = new \OMV\System\Process($cmdArgs);
            $this->buildRepoEnv($repo, $context, $cmd);
            $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();

            $this->writeBgProcOutput($bgOutputFilename, sprintf("Command: %s\n\n", $cmdLine));
            $this->exec($cmdLine, $output, $bgOutputFilename);
            return $output;
        });
    }

    // =========================================================================
    // Environment Variables
    // =========================================================================

    public function getEnvVarList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.getlist');

        $db = \OMV\Config\Database::getInstance();
        $envvars = $db->get('conf.service.restic.envvar');

        $objectsAssoc = [];
        foreach ($envvars as &$envvarv) {
            $envvarv->add('reponame', 'string', gettext("n/a"));
            if ($envvarv->get('reporef') === 'shared') {
                $envvarv->set('reponame', gettext('All Repositories'));
            } else {
                try {
                    $repoObject = $db->get('conf.service.restic.repo', $envvarv->get('reporef'));
                    $envvarv->set('reponame', $repoObject->get('name'));
                } catch (\Exception $e) {}
            }
            $objectsAssoc[] = $envvarv->getAssoc();
        }
        unset($envvarv);

        return $this->applyFilter(
            $objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function getEnvVar($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.restic.envvar', $params['uuid']);
    }

    public function setEnvVar($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.restic.setenvvar');

        // Remove spaces from env var name
        $params['envname'] = str_replace(' ', '_', $params['envname']);

        $envvar = new \OMV\Config\ConfigObject('conf.service.restic.envvar');
        $envvar->setAssoc($params);
        $db = \OMV\Config\Database::getInstance();
        $db->set($envvar);
        return $envvar->getAssoc();
    }

    public function deleteEnvVar($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        $envvar = $db->get('conf.service.restic.envvar', $params['uuid']);
        $db->delete($envvar);
        return $envvar->getAssoc();
    }
}
