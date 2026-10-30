import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

function folder(db, kind) {
  const database = db.sequelize.config.database;
  if (!/^[a-zA-Z0-9_]{1,64}$/.test(database)) throw new Error('Invalid storage namespace.');
  return resolve(fileURLToPath(new URL('../storage/', import.meta.url)), database, kind);
}
export async function saveLeaveAttachment(db, id, value) {
  if (value == null) return;
  if (!Number.isInteger(id) || id < 1) throw new Error('Invalid attachment record.');
  const directory = folder(db, 'leave-attachments');
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, id + '.json'), JSON.stringify(value), { mode: 0o600 });
}
export async function readLeaveAttachment(db, id) {
  try { return JSON.parse(await readFile(join(folder(db, 'leave-attachments'), id + '.json'), 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
export async function saveRawPunch(db, machineID, sr, value) {
  const directory = folder(db, 'raw-punches');
  await mkdir(directory, { recursive: true });
  if (!Number.isInteger(machineID) || !Number.isInteger(sr)) throw new Error('Invalid raw punch record.');
  await writeFile(join(directory, `${machineID}-${sr}.json`), JSON.stringify({ punchRow: sr, machineID, ...value }), { mode: 0o600 });
}
export async function readRawPunch(db, machineID, sr) {
  try { return JSON.parse(await readFile(join(folder(db, 'raw-punches'), `${machineID}-${sr}.json`), 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
