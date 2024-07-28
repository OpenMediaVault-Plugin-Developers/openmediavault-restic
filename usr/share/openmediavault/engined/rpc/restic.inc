<?php
/**
 * Copyright (C) 2013-2024 OpenMediaVault Plugin Developers
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
        // Restic main settings
        $this->registerMethod("getSettings");
        $this->registerMethod("setSettings");
        $this->registerMethod("getResticVersion");

        // Restic repositories
        $this->registerMethod("getRepoList");
        $this->registerMethod("enumerateRepoCandidates");
        $this->registerMethod("getRepo");
        $this->registerMethod("setRepo");
        $this->registerMethod("deleteRepo");

        // Restic snapshots
        $this->registerMethod("getSnapshotList");
        $this->registerMethod("createSnapshot");
        $this->registerMethod("getSnapshot");
        $this->registerMethod("setSnapshot");
        $this->registerMethod("deleteSnapshot");

        // Restic environment variables
        $this->registerMethod('getEnvVarList');
        $this->registerMethod('getEnvVar');
        $this->registerMethod('setEnvVar');
        $this->registerMethod('deleteEnvVar');
    }

    public function getSettings($params, $context)
    {
        // Validate the RPC caller context
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);

        // Get the configuration object from the database "config.xml" 
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.restic.settings");

        // Get the current Restic version, and do not write it to the databsse "config.xml"
        $version = $this->getResticVersion($params, $context);
        $object->add('version', 'string', $version);

        // Return the configuration object for the "Webgui"
        return $object->getAssoc();
    }


    public function setSettings($params, $context)
    {
        // Validate the RPC caller context
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.restic.setsettings');

        // Get the configuration object from the database "config.xml" 
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.restic.settings");

        // Write to the configuration object, ensuring that the keys match that of the properties within conf.service.restic.json
        // usr/share/openmediavault/workbench/component.d/omv-services-restic-settings-form-page.yaml calls `getSettings`
        $object->setFlatAssoc([
            "enable" => $params['enable'],
        ]);

        // Write the configuration object to the database "config.xml"
        $db->set($object);

        // Return the configuration object for the "Webgui"
        return $object->getAssoc();
    }

    public function getResticVersion($params, $context)
    {
        // Make a call to the Restic application, with the `version` argument
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = "version | awk '{print $2}'";
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setRedirect2to1();
        $cmd->execute($output);

        return $output[0];
    }


    public function getRepoList($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');

        // Get the configuration objects from the database "config.xml" 
        $db = \OMV\Config\Database::getInstance();
        $repos = $db->get('conf.service.restic.repo');
        $snapshots = $db->get('conf.service.restic.snapshot');

        // Add additional share information
        $objectsAssoc = [];
        foreach ($repos as $repok => &$repov) {
            // Add the new property 'sharedfoldername'.
            $repov->add('sharedfoldername', 'string', gettext("n/a"));
            if ($repov->get('type') == 'local') {
                // Get the shared folder configuration object.
                $sfObject = $db->get(
                    'conf.system.sharedfolder',
                    $repov->get('sharedfolderref')
                );
                // Update the 'sharedfoldername' property.
                $repov->set('sharedfoldername', $sfObject->get('name'));
            }
            // Get how many snapshots have been created for this repository
            $snapshotCount = 0;
            foreach ($snapshots as $snapshotk => $snapshotv) {
                if ($snapshotv->get('reporef') == $repov->get('uuid')) {
                    $snapshotCount++;
                }
            }
            $repov->add('snapshotCount', 'integer', $snapshotCount);

            $objectsAssoc[] = $repov->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter(
            $objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function enumerateRepoCandidates($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the saved repositories.
        $db = \OMV\Config\Database::getInstance();
        $repos = $db->getAssoc('conf.service.restic.repo');

        // If we are creating an environment variable, we need to allow the user to add
        // an environment variable for all repositories
        if ($params['shared'] == true) {
            $repos[] = [
                'name' => 'All Repositories',
                'uuid' => 'shared'
            ];
        }
        return $repos;
    }

    public function getRepo($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.restic.repo', $params['uuid']);
    }

    public function setRepo($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.restic.setrepo');
        $type = $params['type'];
        // Get the repository via its UUID as per the validation method params RPC datamodel
        $repo = new \OMV\Config\ConfigObject('conf.service.restic.repo');
        $db = \OMV\Config\Database::getInstance();

        // Remove spaces from name
        $params['name'] = str_replace(' ', '_', $params['name']);
        $repo->setAssoc($params);

        // Check if this is a new repository
        $isNew = $repo->isNew();
        if (TRUE === $isNew) {
            // Ensure that the name and shared folder references are unique
            // TODO: This might be where we get a non-user-friendly exception raised in the UI
            $db->assertIsUnique($repo, 'name');
            $db->assertIsUnique($repo, 'sharedfolderref');
        }

        $path = '';
        if ($type == 'local') {
            $path = escapeshellarg(\OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                'uuid' => $params['sharedfolderref']
            ], $context));
        }
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;

        // Initalise the repository, unless we opted to skip initalisation        
        if ($params['skipinit'] == false) {
            $cmdArgs[] = 'init';
            if ($type == 'local') {
                $cmdArgs[] = sprintf("--repo '%s'", $path);
            }

            // Attempt to initialise the repository
            $cmd = new \OMV\System\Process($cmdArgs);
            $cmd->setEnv("RESTIC_PASSWORD", escapeshellarg($params['passphrase']), true);
            if ($type != 'local') {
                $uri = sprintf('%s:%s', $type, $params['uri']);
                $cmd->setEnv("AWS_ACCESS_KEY_ID", escapeshellarg($params['accesskey']));
                $cmd->setEnv("AWS_SECRET_ACCESS_KEY", escapeshellarg($params['secretkey']), true);
                $cmd->setEnv("RESTIC_REPOSITORY", escapeshellarg($uri));
            }
            if (!$isNew) {
                $cmd->setEnvFromFile($this->envFile . $params['uuid']);
            }
            $cmd->setEnvFromFile($this->envFile . 'shared');
            $cmd->setRedirect2to1();
            $cmdLine = $cmd->getCommandLine();
            $cmd->execute($output, $exitStatus);

            // If we cannot, we should raise an exception
            if (0 !== $exitStatus) {
                throw new \OMV\ExecException($cmdLine, $output);
            }
        } else {
            // TODO: We will need to add all of the pre-existing Restic snapshots here...
        };

        // Remove the skipinit parameter
        $repo->remove('skipinit');
        // Set the configuration object.
        $db->set($repo);
        // Return the configuration object.
        return $repo->getAssoc();
    }

    public function deleteRepo($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();

        // Ensure that this repository does not have any snapshots, before deleting it
        $snapshots = $db->get('conf.service.restic.snapshot');
        $found = false;
        foreach ($snapshots as $snapshot) {
            $reporef = $snapshot->get('reporef');
            if ($reporef == $params['uuid']) {
                $found = true;
                break;
            }
        }
        if ($found) {
            throw new \OMV\ExecException(gettext(
              "Repository is in use. Please delete the snapshots associated with this repository first."
            ));
        }

        $repo = $db->get('conf.service.restic.repo', $params['uuid']);

        // Delete repository
        $path = \OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $repo->get('sharedfolderref')
        ], $context);
        $resticRepoFileOrFolder = array("config", "data", "index", "keys", "locks", "snapshots");

        $cmdArgs = [];
        $cmdArgs[] = "rm -rf";
        foreach ($resticRepoFileOrFolder as $fileOrFolder) {
            $cmdArgs[] = escapeshellarg($path . "/" . $fileOrFolder);
        };

        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setQuiet(TRUE);
        $cmd->execute($output);

        // Delete the configuration object.
        $db->delete($repo);
        // Return the deleted configuration object.
        return $repo->getAssoc();
    }

    public function getSnapshotList($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');

        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $snapshots = $db->get('conf.service.restic.snapshot');

        // Add additional repository information to the list.
        $snapshotsAssoc = [];
        foreach ($snapshots as $snapshotk => &$snapshotv) {
            // Add the new property 'reponame' and `sourcename` for display-only
            // purposes in the data table.
            $repo = $db->get('conf.service.restic.repo', $snapshotv->get('reporef'));
            $sharedfoldernames = '';
            $uuids = explode(', ', $snapshotv->get('csvsharedfolderrefs'));

            foreach ($uuids as $i => $uuid) {
                $sharedfolder = $db->get('conf.system.sharedfolder', $uuid);
                $sharedfoldernames .= ($i > 0 ? ', ' : '') . $sharedfolder->get('name');
            }

            $snapshotv->add('reponame', 'string', $repo->get('name'));
            $snapshotv->add('sourcename', 'string', $sharedfoldernames);
            $snapshotsAssoc[] = $snapshotv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter(
            $snapshotsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function getSnapshot($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.restic.snapshot', $params['uuid']);
    }

    public function setSnapshot($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.restic.setsnapshot');

        // We cannot store the list of UUIDv4s, so we will create a CSV and remove
        // sharedfolderrefs from the params
        $sharedfolderefs = '';
        foreach ($params['sharedfolderrefs'] as $i => $uuid) {
            $sharedfolderefs .= ($i > 0 ? ', ' : '') . $uuid;
        }
        unset($params['sharedfolderrefs']);
        $params['csvsharedfolderrefs'] = $sharedfolderefs;

        // Get the snapsot and repo objects.
        $db = \OMV\Config\Database::getInstance();
        $snapshot = new \OMV\Config\ConfigObject('conf.service.restic.snapshot');

        $snapshot->setAssoc($params);
        // Update the snapshot object
        $db->set($snapshot);

        return $snapshot;
    }

    public function createSnapshot($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.restic.setsnapshot');

        // Get the snapsot and repo objects.
        $db = \OMV\Config\Database::getInstance();
        $repo = $db->get('conf.service.restic.repo', $params['reporef']);

        // Create the snapshot background process
        return $this->execBgProc(
            function ($bgStatusFilename, $bgOutputFilename) use ($params, $context, $repo) {
                $repopath = escapeshellarg(\OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
                    'uuid' => $repo->get('sharedfolderref')
                ], $context));

                // sharedfolderrefs is a temporary field and only to be used in this create method
                // csvsharedfolderrefs is where each of these UUIDv4s will be stored, in CSV format
                $sharedfolderpaths = [];
                foreach ($params['sharedfolderrefs'] as $uuid) {
                    $sfpath = escapeshellarg(\OMV\Rpc\Rpc::call("ShareMgmt", "getPath", [
                        "uuid" => $uuid
                    ], $context));
                    $sharedfolderpaths[] = $sfpath;
                }

                // Prepare the Restic backup command
                $cmdArgs = [];
                $cmdArgs[] = $this->getProgram;
                $cmdArgs[] = 'backup';
                $cmdArgs[] = '--verbose';
                $tags = explode(',', $params['tags']);
                foreach ($tags as $tag) {
                    $cmdArgs[] = sprintf('--tag %s', escapeshellarg($tag));
                }
                $excludes = explode(',', $params['exclude']);
                foreach ($excludes as $dirs) {
                    $cmdArgs[] = sprintf('--exclude %s', escapeshellarg($dirs));
                }
                $cmdArgs[] = "-r " . $repopath;
                foreach ($sharedfolderpaths as $path) {
                    $cmdArgs[] = $path;
                }

                $cmd = new \OMV\System\Process($cmdArgs);
                $cmd->setEnv("RESTIC_PASSWORD", escapeshellarg($repo->get('passphrase')));
                $cmd->setEnvFromFile($this->envFile . $repo->get('uuid'));
                $cmd->setEnvFromFile($this->envFile . "shared");
                $cmd->setRedirect2to1();
                $cmdLine = $cmd->getCommandLine();
                
                // Perform the background task
                $this->writeBgProcOutput($bgOutputFilename, sprintf('Command: %s', $cmdLine));
                $this->writeBgProcOutput($bgOutputFilename, PHP_EOL . PHP_EOL);
                $this->exec($cmdLine, $output, $bgOutputFilename);
                
                // Extract the snapshot hash from the command output and update the snapshot object
                // Example output, last line: snapshot 1f66397c saved
                preg_match('/snapshot (\w+) saved/', file_get_contents($bgOutputFilename), $matches);
                $hash = isset($matches[1]) ? $matches[1] : '';
                $params["hash"] = $hash;
                $this->callMethod("setSnapshot", $params, $context);

                return $output;
            }
        );
    }

    public function deleteSnapshot($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        $db = \OMV\Config\Database::getInstance();
        // Get snapshot configuration object
        $snapshot = $db->get('conf.service.restic.snapshot', $params['uuid']);
        // Get repo configuration object
        $repo = $db->get('conf.service.restic.repo', $snapshot->get('reporef'));
        $path = escapeshellarg(\OMV\Rpc\Rpc::call('ShareMgmt', 'getPath', [
            'uuid' => $repo->get('sharedfolderref')
        ], $context));
        // Forget the snapshot. Note: We then need to prune the repository to delete the files
        $cmdArgs = [];
        $cmdArgs[] = $this->getProgram;
        $cmdArgs[] = "-r " . $path;
        $cmdArgs[] = 'forget';
        $cmdArgs[] = $snapshot->get('hash');
       
        $cmd = new \OMV\System\Process($cmdArgs);
        $cmd->setEnv("RESTIC_PASSWORD", escapeshellarg($repo->get('passphrase')));
        $cmd->setEnvFromFile($this->envFile . $snapshot->get('reporef'));
        $cmd->setEnvFromFile($this->envFile . "shared");
        $cmd->setQuiet(TRUE);
        $cmd->execute($output);

        // Delete the configuration object.
        $db->delete($snapshot);
        // Return the deleted configuration object.
        return $snapshot->getAssoc();
    }

    public function getEnvVarList($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.getlist');

        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $envvars = $db->get('conf.service.restic.envvar');
        // Add additional environment variable informations.
        $objectsAssoc = [];
        foreach ($envvars as $envvark => &$envvarv) {
            // Add the new property 'sharedfoldername'.
            $envvarv->add('reponame', 'string', gettext("n/a"));
            // Get the shared folder configuration object.
            if ($envvarv->get('reporef') == 'shared') {
                $envvarv->set('reponame', 'All Repositories');
            } else {
                try {
                    $repoObject = $db->get('conf.service.restic.repo', $envvarv->get('reporef'));
                    // Update the 'reponame' property.
                    $envvarv->set('reponame', $repoObject->get('name'));
                } catch (Exception $e) {
                }
            }
            $objectsAssoc[] = $envvarv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter(
            $objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']
        );
    }

    public function getEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc('conf.service.restic.envvar', $params['uuid']);
    }

    public function setEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.restic.setenvvar');
        // Prepare the configuration object.
        $envvar = new \OMV\Config\ConfigObject('conf.service.restic.envvar');
        // Remove spaces from name
        $params['envname'] = str_replace(' ', '_', $params['envname']);
        // Set the configuration object.
        $envvar->setAssoc($params);
        $db = \OMV\Config\Database::getInstance();
        $db->set($envvar);
        // Return the configuration object.
        return $envvar->getAssoc();
    }

    public function deleteEnvVar($params, $context)
    {
        // Validate the RPC caller context.
        // i.e. you must be an logged on as an administrator to perform this function
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.common.objectuuid');
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $envvar = $db->get('conf.service.restic.envvar', $params['uuid']);
        // Delete the configuration object.
        $db->delete($envvar);
        // Return the deleted configuration object.
        return $envvar->getAssoc();
    }
}
