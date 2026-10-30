import { randomUUID } from 'node:crypto';
import { iso } from './rules.js';
import { insertRecord } from './records.js';
export { records, findRecord, insertRecord, replaceRecord } from './records.js';

export async function lockUser(db, id) { await db.query('SELECT id FROM employees WHERE id=? FOR UPDATE', [id]); }
export async function notice(db, owner, title, kind, id) {
  const destination = kind === 'attendance' ? { attendance: {} } : { [kind]: { _0: id } };
  await insertRecord(db, owner, 'notice', { id: randomUUID(), title, destination, date: iso(), isRead: false });
}
export { registerMachine, machineDetails, mapEmployee, linkStoredEPFRecords, importPunches, markFailure } from './attendance.js';
