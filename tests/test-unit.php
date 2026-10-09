<?php
/**
 * Unit tests for openmediavault-restic that need no root and no running
 * omv-engined: the RPC parameter schemas (checked with openmediavault's own
 * validator) and the RPC service's pure helper methods.
 *
 * Usage: php tests/test-unit.php
 */

require_once "openmediavault/autoloader.inc";
require_once "openmediavault/functions.inc";
require_once "openmediavault/globals.inc";

$root = dirname(__DIR__);
require_once "$root/usr/share/openmediavault/engined/rpc/restic.inc";

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

echo "\n=== RPC methods ===\n";
$registered = (new ReflectionProperty(\OMV\Rpc\ServiceAbstract::class, 'registeredMethods'));
$service->initialize();
$methods = array_keys($registered->getValue($service));
check('createSnapshot is no longer an RPC method (it took unvalidated job params)',
    !in_array('createSnapshot', $methods), implode(', ', $methods));
check('runSnapshot is still an RPC method', in_array('runSnapshot', $methods));

echo "\nResults: $pass passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
