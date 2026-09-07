<?php

/**
 * Boot-time helper for Krayin on Railway.
 *
 * Deliberately plain PDO with no Laravel bootstrap: every one of these steps has
 * to run before the application is installed, i.e. before Laravel can boot at
 * all against the database it is about to create.
 *
 *   env <path> KEY...  rewrite those keys in the .env file from the environment
 *   provision          create the database and the app's scoped MySQL role
 *   wait               block until the scoped role can open the app database
 *   installed          exit 0 when the users table exists and holds a row
 *   admin              replace the seeded admin@example.com account, once
 */

declare(strict_types=1);

function out(string $message): void
{
    fwrite(STDERR, '[railway-helper] '.$message."\n");
}

function envOr(string $key, ?string $default = null): ?string
{
    $value = getenv($key);

    return ($value === false || $value === '') ? $default : $value;
}

function requireEnv(string $key): string
{
    $value = envOr($key);

    if ($value === null) {
        out("ERROR: $key is required");
        exit(1);
    }

    return $value;
}

/**
 * Serialise one .env line. Values are written bare when they cannot be
 * misparsed, and double-quoted otherwise — with `$` escaped, since Dotenv
 * expands ${VAR} inside double quotes and a generated secret can contain one.
 */
function envLine(string $key, string $value): string
{
    if ($value !== '' && preg_match('/\A[A-Za-z0-9_@%+\-.\/:=,\[\]]+\z/', $value) === 1) {
        return $key.'='.$value;
    }

    return $key.'="'.str_replace(['\\', '"', '$'], ['\\\\', '\\"', '\\$'], $value).'"';
}

function commandEnv(array $argv): int
{
    $path = $argv[2] ?? '';

    if ($path === '') {
        out('ERROR: env needs a target path');

        return 1;
    }

    $keys = array_slice($argv, 3);
    $lines = file_exists($path) ? file($path, FILE_IGNORE_NEW_LINES) : [];

    foreach ($keys as $key) {
        $value = getenv($key);

        // An unset variable is left exactly as the file has it, so a value the
        // installer wrote (APP_KEY above all) is never blanked by a later boot.
        if ($value === false) {
            continue;
        }

        $line = envLine($key, (string) $value);
        $found = false;

        foreach ($lines as $i => $existing) {
            if (preg_match('/\A\s*(export\s+)?'.preg_quote($key, '/').'\s*=/', $existing) === 1) {
                $lines[$i] = $line;
                $found = true;

                break;
            }
        }

        if (! $found) {
            $lines[] = $line;
        }
    }

    file_put_contents($path, implode("\n", $lines)."\n");

    return 0;
}

function connect(string $host, string $port, ?string $database, string $user, string $password): PDO
{
    $dsn = "mysql:host=$host;port=$port";

    if ($database !== null && $database !== '') {
        $dsn .= ";dbname=$database";
    }

    return new PDO($dsn, $user, $password, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 10,
    ]);
}

/**
 * Railway's managed MySQL hands out the superuser and nothing else, so the app
 * gets a role of its own here — scoped to its own schema, created over the
 * private network, with no password ever on a public endpoint.
 */
function commandProvision(): int
{
    $host = requireEnv('DB_HOST');
    $port = envOr('DB_PORT', '3306');
    $database = requireEnv('DB_DATABASE');
    $user = requireEnv('DB_USERNAME');
    $password = requireEnv('DB_PASSWORD');

    $adminUser = envOr('DB_ADMIN_USERNAME');
    $adminPassword = envOr('DB_ADMIN_PASSWORD');

    if ($adminUser === null || $adminPassword === null) {
        out('no DB_ADMIN_USERNAME/DB_ADMIN_PASSWORD — assuming the database and role already exist');

        return 0;
    }

    if ($adminUser === $user) {
        out('DB_USERNAME equals DB_ADMIN_USERNAME — skipping provisioning, the app will run as the admin role');

        return 0;
    }

    $lastError = null;

    for ($attempt = 1; $attempt <= 60; $attempt++) {
        try {
            $pdo = connect((string) $host, (string) $port, null, (string) $adminUser, (string) $adminPassword);
            break;
        } catch (Throwable $e) {
            $lastError = $e->getMessage();
            $pdo = null;
            sleep(5);
        }
    }

    if (! isset($pdo) || $pdo === null) {
        out('ERROR: could not reach MySQL as the admin role: '.(string) $lastError);

        return 1;
    }

    $quotedDb = '`'.str_replace('`', '``', (string) $database).'`';
    $quotedUser = $pdo->quote((string) $user);
    $quotedPassword = $pdo->quote((string) $password);

    $pdo->exec("CREATE DATABASE IF NOT EXISTS $quotedDb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $pdo->exec("CREATE USER IF NOT EXISTS $quotedUser@'%' IDENTIFIED BY $quotedPassword");
    $pdo->exec("ALTER USER $quotedUser@'%' IDENTIFIED BY $quotedPassword");
    $pdo->exec(
        'GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, '
        ."CREATE TEMPORARY TABLES, LOCK TABLES ON $quotedDb.* TO $quotedUser@'%'"
    );
    $pdo->exec('FLUSH PRIVILEGES');

    out("provisioned database $database and role $user");

    return 0;
}

function appPdo(): PDO
{
    return connect(
        requireEnv('DB_HOST'),
        (string) envOr('DB_PORT', '3306'),
        requireEnv('DB_DATABASE'),
        requireEnv('DB_USERNAME'),
        requireEnv('DB_PASSWORD')
    );
}

function commandWait(): int
{
    $lastError = null;

    for ($attempt = 1; $attempt <= 60; $attempt++) {
        try {
            appPdo()->query('SELECT 1');
            out('database reachable as the application role');

            return 0;
        } catch (Throwable $e) {
            $lastError = $e->getMessage();
            sleep(5);
        }
    }

    out('ERROR: the application role could not open the database: '.(string) $lastError);

    return 1;
}

/**
 * The same test Krayin's own DatabaseManager uses: a users table holding at
 * least one row. Nothing on the volume is consulted, so a marker file left
 * behind by an unrelated install cannot make an empty database look ready.
 */
function commandInstalled(): int
{
    try {
        $pdo = appPdo();
        $prefix = (string) envOr('DB_PREFIX', '');
        $table = '`'.str_replace('`', '``', $prefix.'users').'`';
        $count = (int) $pdo->query("SELECT COUNT(*) FROM $table")->fetchColumn();

        return $count > 0 ? 0 : 1;
    } catch (Throwable $e) {
        return 1;
    }
}

/**
 * Krayin's UserSeeder inserts admin@example.com / admin123 as user 1 on every
 * fresh install, with no way to change it. This replaces that row immediately
 * after the install, before anything is listening — so those credentials are
 * never valid on a reachable deployment.
 *
 * Only ever called from the fresh-install branch of the entrypoint, so it can
 * never revert a password an operator changed later.
 */
function commandAdmin(): int
{
    $name = (string) envOr('ADMIN_NAME', 'Administrator');
    $email = requireEnv('ADMIN_EMAIL');
    $password = requireEnv('ADMIN_PASSWORD');

    if (! filter_var($email, FILTER_VALIDATE_EMAIL)) {
        out("ERROR: ADMIN_EMAIL is not a valid address: $email");

        return 1;
    }

    // cost 10 matches what Krayin's own installer and web setup wizard write;
    // Laravel verifies any cost on login.
    $hash = password_hash($password, PASSWORD_BCRYPT, ['cost' => 10]);

    try {
        $pdo = appPdo();
        $prefix = (string) envOr('DB_PREFIX', '');
        $table = '`'.str_replace('`', '``', $prefix.'users').'`';

        $statement = $pdo->prepare(
            "UPDATE $table SET name = :name, email = :email, password = :password, "
            .'status = 1, role_id = 1, remember_token = NULL, updated_at = NOW() WHERE id = 1'
        );
        $statement->execute([
            ':name' => $name,
            ':email' => $email,
            ':password' => $hash,
        ]);

        if ($statement->rowCount() === 0) {
            $check = $pdo->prepare("SELECT COUNT(*) FROM $table WHERE id = 1 AND email = :email");
            $check->execute([':email' => $email]);

            if ((int) $check->fetchColumn() === 0) {
                out('ERROR: no user with id 1 to replace — the installer did not seed one');

                return 1;
            }
        }

        $stale = $pdo->prepare("SELECT COUNT(*) FROM $table WHERE email = 'admin@example.com'");
        $stale->execute();

        if ((int) $stale->fetchColumn() > 0) {
            out('ERROR: the seeded admin@example.com account is still present');

            return 1;
        }

        out("first admin set to $email");

        return 0;
    } catch (Throwable $e) {
        out('ERROR: could not set the first admin: '.$e->getMessage());

        return 1;
    }
}

$command = $argv[1] ?? '';

exit(match ($command) {
    'env' => commandEnv($argv),
    'provision' => commandProvision(),
    'wait' => commandWait(),
    'installed' => commandInstalled(),
    'admin' => commandAdmin(),
    default => (function () use ($command): int {
        out("unknown command: '$command'");

        return 2;
    })(),
});
