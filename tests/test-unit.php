<?php
/**
 * Unit tests for openmediavault-restic that need no root and no running
 * omv-engined: the RPC parameter schemas (checked with openmediavault's own
 * validator), the RPC service's helper methods and the RPC methods that only
 * touch the configuration database, run against a temporary copy of it.
 *
 * Usage: php tests/test-unit.php   (the UI pattern test also needs node)
 */

require_once "openmediavault/autoloader.inc";
require_once "openmediavault/functions.inc";
require_once "openmediavault/globals.inc";

$root = dirname(__DIR__);
require_once "$root/usr/share/openmediavault/engined/rpc/restic.inc";

// A temporary configuration database, with this tree's data models in place
// of the installed ones, so no root and no live config.xml are needed.
$tmpDir = sys_get_temp_dir() . '/restic-unit-test-' . getmypid();
mkdir("$tmpDir/datamodels", 0700, true);
mkdir("$tmpDir/env", 0700);
register_shutdown_function(function () use ($tmpDir) {
    exec('rm -rf ' . escapeshellarg($tmpDir));
});
foreach (glob('/usr/share/openmediavault/datamodels/*.json') as $f) {
    symlink($f, "$tmpDir/datamodels/" . basename($f));
}
foreach (glob("$root/usr/share/openmediavault/datamodels/*.json") as $f) {
    @unlink("$tmpDir/datamodels/" . basename($f));
    symlink($f, "$tmpDir/datamodels/" . basename($f));
}
const SF_ONE = 'aaaaaaaa-0000-4000-8000-000000000001';
const SF_TWO = 'aaaaaaaa-0000-4000-8000-000000000002';
const REPO_LOCAL = 'bbbbbbbb-0000-4000-8000-000000000001';
const REPO_REST = 'bbbbbbbb-0000-4000-8000-000000000002';
file_put_contents("$tmpDir/config.xml", '<?xml version="1.0" encoding="UTF-8"?>
<config><services><restic>
  <settings><cachedir>/var/cache/restic-test</cachedir><exclude></exclude><excludecaches>0</excludecaches></settings>
  <repos>
    <repo><uuid>' . REPO_LOCAL . '</uuid><name>local1</name><type>local</type><sharedfolderref>' . SF_ONE . '</sharedfolderref><passphrase>p1</passphrase></repo>
    <repo><uuid>' . REPO_REST . '</uuid><name>rest1</name><type>rest</type><sharedfolderref></sharedfolderref><uri>http://host/repo</uri><passphrase>p2</passphrase></repo>
  </repos>
</restic></services></config>
');
\OMV\Environment::set('OMV_DATAMODELS_DIR', "$tmpDir/datamodels");
\OMV\Environment::set('OMV_CONFIG_FILE', "$tmpDir/config.xml");
\OMV\DataModel\Manager::getInstance()->load();

$pass = 0;
$fail = 0;

function check($desc, $ok, $detail = '')
{
    global $pass, $fail;
    if ($ok) {
        $pass++;
        echo "  PASS  $desc\n";
    } else {
        $fail++;
        echo "  FAIL  $desc" . ($detail !== '' ? "\n        -> $detail" : '') . "\n";
    }
}

// ---------------------------------------------------------------------------
// RPC parameter schemas
// ---------------------------------------------------------------------------
$schemas = [];
foreach (json_decode(file_get_contents(
        "$root/usr/share/openmediavault/datamodels/rpc.restic.json"), true) as $s) {
    $schemas[$s['id']] = $s['params'];
}

function valid($id, array $params)
{
    global $schemas;
    try {
        (new \OMV\DataModel\Schema($schemas[$id]))->validate($params);
        return true;
    } catch (\Exception $e) {
        return false;
    }
}

function expectValid($id, array $params, $desc)
{
    check("$id accepts $desc", valid($id, $params));
}

function expectInvalid($id, array $params, $desc)
{
    check("$id rejects $desc", !valid($id, $params));
}

const NEW_UUID = 'fa4b1c66-ef79-11e5-87a0-0002b3a176b4';

echo "\n=== Schemas: snapshot IDs and REST users (no trailing newline) ===\n";
$snap = ['reporef' => NEW_UUID, 'snapshotid' => 'abcdef12'];
expectValid('rpc.restic.reposnapshot', $snap, 'a hex ID');
expectInvalid('rpc.restic.reposnapshot', ['snapshotid' => "abcdef12\n"] + $snap,
    'an ID with a trailing newline');
$forget = ['reporef' => NEW_UUID, 'snapshotids' => 'abcdef12,0123abcd'];
expectValid('rpc.restic.forgetreposnapshots', $forget, 'a list of hex IDs');
expectInvalid('rpc.restic.forgetreposnapshots', ['snapshotids' => "abcdef12,0123abcd\n"] + $forget,
    'a list with a trailing newline');
$user = ['uuid' => NEW_UUID, 'username' => 'alice', 'password' => 'x'];
expectValid('rpc.restic.setrestuser', $user, 'a plain username');
expectInvalid('rpc.restic.setrestuser', ['username' => "alice\n"] + $user,
    'a username with a trailing newline (extra htpasswd line)');

echo "\n=== Schemas: environment variables ===\n";
$env = ['uuid' => NEW_UUID, 'envname' => 'AWS_REGION', 'envvalue' => 'x', 'reporef' => 'shared'];
expectValid('rpc.restic.setenvvar', $env, 'a shell variable name');
expectValid('rpc.restic.setenvvar', ['envvalue' => 'pa$$ `x` "y" \'z\' \\'] + $env,
    'a value with shell metacharacters');
foreach (['MY-VAR', '1VAR', 'A=B', 'A B', "A\n", ''] as $name) {
    expectInvalid('rpc.restic.setenvvar', ['envname' => $name] + $env,
        'name ' . json_encode($name));
}
foreach (["a\nb", "a\rb", "value\n"] as $value) {
    expectInvalid('rpc.restic.setenvvar', ['envvalue' => $value] + $env,
        'value ' . json_encode($value));
}

echo "\n=== Schemas: names and schedules of jobs ===\n";
$job = [
    'uuid' => NEW_UUID, 'name' => 'job', 'hash' => '', 'tags' => '',
    'sharedfolderrefs' => [NEW_UUID], 'reporef' => NEW_UUID, 'exclude' => '',
    'execution' => 'exactly', 'minute' => ['0', '30'], 'everynminute' => false,
    'hour' => ['*'], 'everynhour' => false, 'dayofmonth' => ['*'],
    'everyndayofmonth' => false, 'month' => ['*'], 'dayofweek' => ['1', '7'],
];
expectValid('rpc.restic.setsnapshot', $job, 'a normal job');
expectValid('rpc.restic.setsnapshot', ['name' => 'Bob\'s "nightly" $(job)'] + $job,
    'a name with quotes and $');
expectInvalid('rpc.restic.setsnapshot', ['name' => "a\nb"] + $job, 'a name with a newline');
expectInvalid('rpc.restic.setsnapshot', ['minute' => ["0\n* * * * * root id"]] + $job,
    'a schedule value that injects a cron line');
expectInvalid('rpc.restic.setsnapshot', ['hour' => ['*/2']] + $job,
    'a schedule value that is not a number or *');

$rt = [
    'uuid' => NEW_UUID, 'name' => 'rt', 'reporef' => NEW_UUID, 'mode' => 'dryrun',
    'execution' => 'exactly', 'minute' => ['0'], 'everynminute' => false,
    'hour' => ['0'], 'everynhour' => false, 'dayofmonth' => ['*'],
    'everyndayofmonth' => false, 'month' => ['*'], 'dayofweek' => ['*'],
];
expectValid('rpc.restic.setrestoretest', $rt, 'a normal restore test');
expectInvalid('rpc.restic.setrestoretest', ['name' => "a\rb"] + $rt, 'a name with a CR');
expectInvalid('rpc.restic.setrestoretest', ['dayofweek' => ['1;id']] + $rt,
    'a schedule value with shell characters');

$repo = [
    'uuid' => NEW_UUID, 'name' => 'repo', 'type' => 'rest', 'sharedfolderref' => '',
    'passphrase' => 'x', 'skipinit' => true,
];
expectValid('rpc.restic.setrepo', $repo, 'a normal repository');
expectInvalid('rpc.restic.setrepo', ['name' => "repo\n"] + $repo, 'a name with a newline');
expectInvalid('rpc.restic.setrepo', ['forgethost' => "host\n"] + $repo,
    'a retention host with a trailing newline');
foreach (['5%', '2.5%', '1/7', '500M', ''] as $v) {
    expectValid('rpc.restic.setrepo', ['checkreaddata' => $v] + $repo, "read data subset '$v'");
}
expectInvalid('rpc.restic.setrepo', ['checkreaddata' => "5%\n"] + $repo,
    'a read data subset with a trailing newline');
expectValid('rpc.restic.setrepo', ['connections' => 10] + $repo, '10 connections');
expectInvalid('rpc.restic.setrepo', ['connections' => -1] + $repo, 'negative connections');
expectValid('rpc.restic.setrepo', ['options' => "s3.region=us-east-1\r\nrclone.args=serve restic --stdio\n"] + $repo,
    'multi-line extended options');
expectInvalid('rpc.restic.setrepo', ['options' => "s3.region=x\x1b[2J"] + $repo,
    'extended options with a control character');

echo "\n=== Schemas: deleteRepo ===\n";
expectValid('rpc.restic.deleterepo', ['uuid' => NEW_UUID], 'a UUID only (keeps data)');
expectValid('rpc.restic.deleterepo', ['uuid' => NEW_UUID, 'deletedata' => true], 'deletedata=true');
expectInvalid('rpc.restic.deleterepo', ['uuid' => NEW_UUID, 'deletedata' => 'yes'],
    'a non-boolean deletedata');

// ---------------------------------------------------------------------------
// RPC service helpers
// ---------------------------------------------------------------------------
$service = new OMVRpcServiceRestic();

function callPrivate($obj, $method, array $args)
{
    $m = new ReflectionMethod($obj, $method);
    return $m->invokeArgs($obj, $args);
}

echo "\n=== buildCronSchedule (must match cron_field in default.sls) ===\n";
$base = [
    'execution' => 'exactly', 'minute' => '0', 'everynminute' => false,
    'hour' => '0', 'everynhour' => false, 'dayofmonth' => '*',
    'everyndayofmonth' => false, 'month' => '*', 'dayofweek' => '*',
];
$cases = [
    [['minute' => '15', 'everynminute' => true], '*/15 0 * * *'],
    [['minute' => '*', 'everynminute' => true], '* 0 * * *'],
    [['minute' => '0', 'everynminute' => true], '0 0 * * *'],
    [['minute' => '0,30', 'everynminute' => true], '0,30 0 * * *'],
    [['hour' => '6', 'everynhour' => true], '0 */6 * * *'],
    [['dayofmonth' => '2', 'everyndayofmonth' => true, 'dayofweek' => '1'], '0 0 */2 * 1'],
    [['execution' => 'weekly'], '0 0 * * 0'],
    [['execution' => 'reboot'], '@reboot'],
];
foreach ($cases as [$kw, $expected]) {
    $got = callPrivate($service, 'buildCronSchedule', [$kw + $base, 'daily']);
    check(json_encode($kw) . " -> '$expected'", $got === $expected, "got '$got'");
}

echo "\n=== normaliseSchedule ===\n";
$params = ['minute' => ['0', '30'], 'hour' => ['*'], 'dayofmonth' => ['*'],
    'month' => ['*'], 'dayofweek' => ['1', '2'], 'execution' => 'exactly'] + $base;
callPrivate($service, 'normaliseSchedule', [&$params]);
check('arrays are stored as CSV', $params['minute'] === '0,30' && $params['dayofweek'] === '1,2');

$rejected = [
    ['minute' => ['0', '30'], 'everynminute' => true],
    ['minute' => ['*'], 'everynminute' => true],
    ['minute' => ['0'], 'everynminute' => true],
    ['hour' => ['*'], 'everynhour' => true],
    ['dayofmonth' => ['1', '15'], 'everyndayofmonth' => true],
];
foreach ($rejected as $kw) {
    $params = $kw + ['minute' => ['0'], 'hour' => ['0'], 'dayofmonth' => ['*'],
        'month' => ['*'], 'dayofweek' => ['*']] + $base;
    try {
        callPrivate($service, 'normaliseSchedule', [&$params]);
        check('rejects "every N" with ' . json_encode($kw), false, 'no exception');
    } catch (\OMV\Exception $e) {
        check('rejects "every N" with ' . json_encode($kw), true);
    }
}
$params = ['minute' => ['15'], 'everynminute' => true, 'hour' => ['*'],
    'dayofmonth' => ['*'], 'month' => ['*'], 'dayofweek' => ['*']] + $base;
try {
    callPrivate($service, 'normaliseSchedule', [&$params]);
    check('accepts "every 15 minutes"', $params['minute'] === '15');
} catch (\OMV\Exception $e) {
    check('accepts "every 15 minutes"', false, $e->getMessage());
}
$params = ['minute' => ['0', '30'], 'everynminute' => true, 'hour' => ['*'],
    'dayofmonth' => ['*'], 'month' => ['*'], 'dayofweek' => ['*'], 'execution' => 'daily'] + $base;
try {
    callPrivate($service, 'normaliseSchedule', [&$params]);
    check('ignores "every N" when the execution is not a certain date', true);
} catch (\OMV\Exception $e) {
    check('ignores "every N" when the execution is not a certain date', false, $e->getMessage());
}

echo "\n=== Repository extended options (must match default.sls) ===\n";
class FakeRepo
{
    private $data;
    public function __construct(array $data) { $this->data = $data; }
    public function get($key) { return $this->data[$key] ?? null; }
}
$opts = callPrivate($service, 'parseRepoOptions', ["  s3.region=us-east-1 \r\n\n\trclone.args=serve restic --stdio\r"]);
check('parses lines, trims them and skips blank lines',
    $opts === ['s3.region=us-east-1', 'rclone.args=serve restic --stdio'], json_encode($opts));
check('parses an empty value', callPrivate($service, 'parseRepoOptions', ['']) === []);
foreach (['region=x', '--repo=/tmp/x', 'S3.region=x', 's3.region', "s3.region=a\x0bb", '-o s3.region=x'] as $bad) {
    try {
        callPrivate($service, 'parseRepoOptions', [$bad]);
        check('rejects option ' . json_encode($bad), false, 'no exception');
    } catch (\OMV\Exception $e) {
        check('rejects option ' . json_encode($bad), true);
    }
}
$args = callPrivate($service, 'buildRepoOptions', [new FakeRepo(
    ['type' => 's3', 'connections' => '10', 'options' => "s3.region=it's \$(id)"])]);
check('connections map to the backend type and values are shell-quoted',
    $args === ["-o 's3.connections=10'", "-o 's3.region=it'\\''s \$(id)'"], json_encode($args));
check('no options when connections is 0 and options are empty',
    callPrivate($service, 'buildRepoOptions', [new FakeRepo(
        ['type' => 'b2', 'connections' => 0, 'options' => ''])]) === []);
$cmd = callPrivate($service, 'addRepoOptions', [new FakeRepo(
    ['type' => 'b2', 'connections' => 8, 'options' => '']), ['/usr/bin/restic', 'check', '--retry-lock', '5m']]);
check('options go after the subcommand',
    $cmd === ['/usr/bin/restic', 'check', "-o 'b2.connections=8'", '--retry-lock', '5m'], json_encode($cmd));

echo "\n=== Extended options: UI pattern agrees with parseRepoOptions ===\n";
$yaml = file_get_contents(
    "$root/usr/share/openmediavault/workbench/component.d/omv-services-restic-repo-create-form-page.yaml");
preg_match("/name: options\n(?:.*\n)*?\s+pattern: '([^']*)'/", $yaml, $m);
$uiPattern = $m[1] ?? '';
check('found the UI pattern of the options field', $uiPattern !== '');
$optionInputs = [
    '', "s3.region=us-east-1", "  s3.region=us-east-1 \t", "s3.region=a b\nb2.connections=5\n",
    "s3.region=x\r\n\r\nrclone.args=serve restic --stdio\r\n", "\t\n  \n",
    "s3.region=a\tb", "s3.region=a\x01b", "s3.region=a\x7fb", 'region=x', 'S3.region=x',
    's3.region', '-o s3.region=x', "s3.region=x\nfoo",
];
if (trim(shell_exec('command -v node') ?? '') === '') {
    echo "  SKIP  node not available\n";
} else {
    $js = 'const p = new RegExp(process.argv[1]); let d = "";'
        . 'process.stdin.on("data", c => d += c).on("end", () =>'
        . ' console.log(JSON.stringify(JSON.parse(d).map(s => p.test(s)))));';
    $proc = proc_open(['node', '-e', $js, $uiPattern], [0 => ['pipe', 'r'], 1 => ['pipe', 'w']], $pipes);
    fwrite($pipes[0], json_encode($optionInputs));
    fclose($pipes[0]);
    $uiResults = json_decode(stream_get_contents($pipes[1]), true);
    proc_close($proc);
    foreach ($optionInputs as $i => $input) {
        try {
            callPrivate($service, 'parseRepoOptions', [$input]);
            $rpcOk = true;
        } catch (\OMV\Exception $e) {
            $rpcOk = false;
        }
        check(sprintf('%s: UI and RPC both %s it', json_encode($input), $rpcOk ? 'accept' : 'reject'),
            ($uiResults[$i] ?? null) === $rpcOk,
            sprintf('UI %s, RPC %s', json_encode($uiResults[$i] ?? null), json_encode($rpcOk)));
    }
}

echo "\n=== buildRepoEnv: env var precedence (must match the salt scripts) ===\n";
(new ReflectionProperty($service, 'envFile'))->setValue($service, "$tmpDir/env/restic-envvar-");
file_put_contents("$tmpDir/env/restic-envvar-shared",
    "PRECEDENCE_SHARED='shared'\nPRECEDENCE_BOTH='shared'\nRESTIC_PASSWORD='shared'\n" .
    "RESTIC_REPOSITORY='shared'\nRESTIC_CACHE_DIR='shared'\n");
file_put_contents("$tmpDir/env/restic-envvar-" . REPO_REST,
    "PRECEDENCE_BOTH='repo'\nRESTIC_REPOSITORY='repo'\n");
$cmd = new \OMV\System\Process(['env', '-0']);
$restRepo = \OMV\Config\Database::getInstance()->get('conf.service.restic.repo', REPO_REST);
callPrivate($service, 'buildRepoEnv', [$restRepo, [], &$cmd]);
exec($cmd->getCommandLine(), $envOut);
$env = [];
foreach (explode("\0", implode("\n", $envOut)) as $item) {
    if (strpos($item, '=') !== false) {
        [$k, $v] = explode('=', $item, 2);
        $env[$k] = $v;
    }
}
foreach ([
    'PRECEDENCE_SHARED' => 'shared',
    'PRECEDENCE_BOTH' => 'repo',
    'RESTIC_REPOSITORY' => 'rest:http://host/repo',
    'RESTIC_PASSWORD' => 'p2',
    'RESTIC_CACHE_DIR' => '/var/cache/restic-test',
] as $k => $expected) {
    check("$k = '$expected'", ($env[$k] ?? null) === $expected, 'got ' . json_encode($env[$k] ?? null));
}

echo "\n=== setRepo: unique name and shared folder, also on edit ===\n";
$ctx = ['username' => 'admin', 'role' => OMV_ROLE_ADMINISTRATOR];
function setRepoOk($params, $desc)
{
    global $service, $ctx;
    try {
        $service->setRepo($params + ['sharedfolderref' => '', 'skipinit' => true], $ctx);
        check($desc, true);
    } catch (\Exception $e) {
        check($desc, false, $e->getMessage());
    }
}
function setRepoFails($params, $desc)
{
    global $service, $ctx;
    try {
        $service->setRepo($params + ['sharedfolderref' => '', 'skipinit' => true], $ctx);
        check($desc, false, 'no exception');
    } catch (\OMV\AssertException $e) {
        check($desc, true);
    }
}
$restEdit = ['uuid' => REPO_REST, 'name' => 'rest1', 'type' => 'rest',
    'uri' => 'http://host/repo', 'passphrase' => 'p2'];
$localEdit = ['uuid' => REPO_LOCAL, 'name' => 'local1', 'type' => 'local',
    'sharedfolderref' => SF_ONE, 'passphrase' => 'p1'];
setRepoFails(['uuid' => NEW_UUID, 'name' => 'rest1'] + $restEdit, 'a new repo cannot reuse a name');
setRepoFails(['name' => 'local1'] + $restEdit, 'an edited repo cannot be renamed to another repo\'s name');
setRepoOk($restEdit, 'an edited repo can keep its own name');
setRepoFails(['uuid' => NEW_UUID, 'name' => 'local2'] + $localEdit,
    'a new local repo cannot reuse a shared folder');
setRepoOk(['uuid' => NEW_UUID, 'name' => 'local2', 'sharedfolderref' => SF_TWO] + $localEdit,
    'a new local repo can use another shared folder');
setRepoFails(['sharedfolderref' => SF_TWO] + $localEdit,
    'an edited local repo cannot move to another repo\'s shared folder');
setRepoOk($localEdit, 'an edited local repo can keep its own shared folder');

echo "\n=== RPC methods ===\n";
$registered = (new ReflectionProperty(\OMV\Rpc\ServiceAbstract::class, 'registeredMethods'));
$service->initialize();
$methods = array_keys($registered->getValue($service));
check('createSnapshot is no longer an RPC method (it took unvalidated job params)',
    !in_array('createSnapshot', $methods), implode(', ', $methods));
check('runSnapshot is still an RPC method', in_array('runSnapshot', $methods));

echo "\nResults: $pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
