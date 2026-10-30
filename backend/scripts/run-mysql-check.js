import { spawnSync } from 'node:child_process';
const result = spawnSync(process.execPath, ['--test', '--test-concurrency=1', 'test/mysql.integration.test.js'], {
  stdio: 'inherit', env: { ...process.env, RUN_MYSQL_TESTS: 'true' }
});
process.exitCode = result.status ?? 1;
