import { writeFile, mkdir } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { loadEnvironment, loadConfig } from '../src/config.js';
import { database } from '../src/db.js';
import { readDevice, deviceError, settingsFromMachine } from '../src/fingerprint.js';
import { machineSelect, machineID } from '../src/attendance.js';
loadEnvironment();
let db;
try {
  const { values } = parseArgs({ options: { machine: { type: 'string' } } });
  db = database(loadConfig().database);
  const machines = await db.query(machineSelect + ' WHERE m.active=1 AND m.sync_enabled=1' + (values.machine ? ' AND m.id=?' : '') + ' ORDER BY m.id', values.machine ? [machineID(values.machine)] : []);
  if (!machines.length) throw new Error('No active, sync-enabled machines were found in punch_machine.');
  await mkdir(new URL('../../output/', import.meta.url), { recursive: true });
  for (const machine of machines) {
    const rows = await readDevice(settingsFromMachine(machine));
    const file = `machine-${machine.id}-punches.json`;
    await writeFile(new URL('../../output/' + file, import.meta.url), JSON.stringify(rows, null, 2), { mode: 0o600 });
    console.log(JSON.stringify({ source: 'punch_machine + node-zklib', machineID: machine.id, records: rows.length, output: 'output/' + file }));
  }
} catch (error) { console.error(error.code ? deviceError(error) : error.message); process.exitCode = 1; }
finally { await db?.close(); }
