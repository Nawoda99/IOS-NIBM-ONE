import { isIP } from 'node:net';
import { DateTime } from 'luxon';
import { ensureBranch } from './records.js';
import { HTTPError, iso, normalisedPunch, required } from './rules.js';
import { appID, canonicalEPF } from './identity.js';
import { saveRawPunch, readRawPunch } from './files.js';
import { enqueuePunchNotification } from './push.js';

export const machineSelect = `SELECT m.*,b.description AS branch,c.companyId FROM punch_machine m
  JOIN companybranch c ON c.id=m.companyBranchId JOIN branch b ON b.id=c.branchId`;
export const numericEPF = value => Number(canonicalEPF(value));
// The exact backup has no timezone or direction-map columns. Preserve raw flags and leave unknown meanings explicit.
export const ATTENDANCE_SETTINGS = Object.freeze({ timezone: 'Asia/Colombo', directionMap: Object.freeze({}) });
export function machineID(code) {
  const match = /^(?:machine-)?([1-9]\d*)$/.exec(String(code));
  if (!match || Number(match[1]) > 2147483647) throw new HTTPError(400, 'Use the machine ID returned by machine registration.');
  return Number(match[1]);
}
export async function registerMachine(db, input) {
  const name = required(input.name, 'machine name', 255), branch = required(input.branch, 'branch', 255);
  if (input.idsAreEPF === false) throw new HTTPError(400, 'Machine attendance must use EPF numbers.');
  if (input.ip !== undefined && (typeof input.ip !== 'string' || !isIP(input.ip))) throw new HTTPError(400, 'Invalid machine IP address.');
  for (const [key, min, max] of [['port', 1, 65535], ['timeout', 100, 60000]]) if (input[key] !== undefined && (!Number.isInteger(input[key]) || input[key] < min || input[key] > max)) throw new HTTPError(400, 'Invalid machine ' + key + '.');
  if (input.enabled !== undefined && typeof input.enabled !== 'boolean') throw new HTTPError(400, 'Invalid machine polling setting.');
  return db.transaction(async tx => {
    const branchID = await ensureBranch(tx, branch), now = new Date();
    let [company] = await tx.query('SELECT id FROM company WHERE companyname=? ORDER BY id LIMIT 1 FOR UPDATE', ['NIBM']);
    if (!company) company = { id: (await tx.query('INSERT INTO company (companyname,createdAt,updatedAt) VALUES (?,?,?)', ['NIBM', now, now])).insertId };
    let [companyBranch] = await tx.query('SELECT id FROM companybranch WHERE companyId=? AND branchId=? FOR UPDATE', [company.id, branchID]);
    if (!companyBranch) companyBranch = { id: (await tx.query('INSERT INTO companybranch (companyId,branchId) VALUES (?,?)', [company.id, branchID])).insertId };
    let existing;
    if (input.machineID != null) {
      [existing] = await tx.query('SELECT id FROM punch_machine WHERE id=? FOR UPDATE', [machineID(input.machineID)]);
      if (!existing) throw new HTTPError(404, 'Configured fingerprint machine ID was not found.');
    } else if (input.ip) [existing] = await tx.query('SELECT id FROM punch_machine WHERE machine_ip=? AND machine_port=? ORDER BY id LIMIT 1 FOR UPDATE', [input.ip, input.port ?? 4370]);
    const fields = { machine_description: name, companyBranchId: companyBranch.id, updatedAt: now };
    for (const [key, column] of [['model', 'machine_model'], ['ip', 'machine_ip'], ['port', 'machine_port'], ['timeout', 'machine_timeout'], ['enabled', 'sync_enabled']]) if (input[key] !== undefined) fields[column] = input[key];
    if (input.pollSeconds !== undefined) fields.sync_interval_minutes = Math.max(1, Math.ceil(input.pollSeconds / 60));
    let id = existing?.id;
    if (id == null) {
      fields.machine_model ??= 'T900'; fields.createdAt = now; fields.sdk_library = 'node-zklib';
      id = (await tx.query(`INSERT INTO punch_machine (${Object.keys(fields).join(',')}) VALUES (${Object.keys(fields).map(() => '?').join(',')})`, Object.values(fields))).insertId;
    } else await tx.query(`UPDATE punch_machine SET ${Object.keys(fields).map(key => key + '=?').join(',')} WHERE id=?`, [...Object.values(fields), id]);
    return (await tx.query(machineSelect + ' WHERE m.id=?', [id]))[0];
  });
}
export function machineDetails(row) {
  return { code: 'machine-' + row.id, name: row.machine_description ?? row.machine_model, branch: row.branch,
    model: row.machine_model, ipAddress: row.machine_ip, port: row.machine_port, usesEPFNumbers: true,
    enabled: Boolean(row.active && row.sync_enabled), lastSyncedAt: row.last_synced_at ? iso(row.last_synced_at) : null,
    lastError: row.last_sync_status === 'FAILED' ? row.last_sync_message : null };
}
export async function mapEmployee(db, code, input) {
  const epf = canonicalEPF(input.epfNo);
  if (input.deviceUserID !== undefined && canonicalEPF(input.deviceUserID) !== epf) throw new HTTPError(409, 'Machine EPF and employee EPF must match.');
  const [machine] = code == null ? [{ id: null }] : await db.query('SELECT id FROM punch_machine WHERE id=?', [machineID(code)]);
  const [employee] = await db.query('SELECT id FROM employees WHERE epf_no=?', [Number(epf)]);
  if (!machine || !employee) throw new HTTPError(404, 'Register the machine and employee EPF first.');
}
export async function linkStoredEPFRecords() { /* Ownership follows the backup's numeric EPF directly. */ }
export async function importPunches(db, code, input, complete = true, settings = {}) {
  if (!Array.isArray(input) || input.length > 1000) throw new HTTPError(400, 'Use a batch of at most 1000 punches.');
  const punches = input.map(normalisedPunch).map(punch => ({ ...punch, epfNo: canonicalEPF(punch.epfNo) }));
  const id = machineID(code), evidence = [];
  const result = await db.transaction(async tx => {
    const [machine] = await tx.query(machineSelect + ' WHERE m.id=? FOR UPDATE', [id]);
    if (!machine) throw new HTTPError(404, 'Register the machine first.');
    const totals = { inserted: 0, duplicates: 0, unmapped: 0 };
    for (const punch of punches) {
      const local = DateTime.fromISO(punch.timestamp).setZone(settings.timezone ?? 'Asia/Colombo');
      const flag = punch.rawPunch == null ? punch.direction : String(punch.rawPunch);
      let [row] = await tx.query(`SELECT sr FROM punches WHERE emp_epf_no=? AND pun_machine_id=? AND pun_date=? AND pun_time=?
        AND (pun_flag=? OR pun_flag IS NULL) AND COALESCE(manual,0)=0 ORDER BY sr LIMIT 1 FOR UPDATE`, [Number(punch.epfNo), id, local.toISODate(), local.toFormat('HH:mm:ss'), flag]);
      const isNew = !row;
      if (row) totals.duplicates++;
      else {
        row = { sr: (await tx.query(`INSERT INTO punches (pun_date,pun_time,emp_epf_no,pun_machine_id,pun_flag,company_id,downloaded_on,original_epf_no)
          VALUES (?,?,?,?,?,?,?,?)`, [local.toISODate(), local.toFormat('HH:mm:ss'), Number(punch.epfNo), id, flag, String(machine.companyId), new Date(), Number(punch.epfNo)])).insertId };
        totals.inserted++;
      }
      const [employee] = await tx.query('SELECT id FROM employees WHERE epf_no=?', [Number(punch.epfNo)]);
      if (!employee) totals.unmapped++;
      else if (isNew) await enqueuePunchNotification(tx, employee.id, row.sr, punch, machine);
      evidence.push({ sr: row.sr, punch });
    }
    return totals;
  });
  for (const item of evidence) await saveRawPunch(db, id, item.sr, item.punch);
  if (complete) await db.query("UPDATE punch_machine SET last_synced_at=?,last_sync_status='SUCCESS',last_sync_message=NULL WHERE id=?", [new Date(), id]);
  return result;
}
export async function markFailure(db, code, message) {
  await db.query("UPDATE punch_machine SET last_sync_status='FAILED',last_sync_message=? WHERE id=?", [String(message).slice(0, 250), machineID(code)]);
}
export async function attendanceRecords(db, epfNo, cutoff, settings = {}, endExclusive = null) {
  const rows = await db.query(`SELECT p.*,m.machine_description,m.machine_model,b.description AS branch FROM punches p
    LEFT JOIN punch_machine m ON m.id=p.pun_machine_id LEFT JOIN companybranch c ON c.id=m.companyBranchId LEFT JOIN branch b ON b.id=c.branchId
    WHERE p.emp_epf_no=? AND COALESCE(p.invalid,0)=0 AND p.pun_date>=?${endExclusive == null ? '' : ' AND p.pun_date < ?'} ORDER BY p.pun_date,p.pun_time,p.sr`,
  [numericEPF(epfNo), DateTime.fromJSDate(cutoff).setZone(settings.timezone ?? 'Asia/Colombo').toISODate(),
    ...(endExclusive == null ? [] : [DateTime.fromJSDate(endExclusive).setZone(settings.timezone ?? 'Asia/Colombo').toISODate()])]);
  const result = [];
  for (const row of rows) {
    const local = DateTime.fromISO(row.pun_date + 'T' + row.pun_time, { zone: settings.timezone ?? 'Asia/Colombo' });
    if (!local.isValid) continue;
    const time = local.toJSDate();
    if (time < cutoff || (endExclusive != null && time >= endExclusive)) continue;
    const raw = await readRawPunch(db, row.pun_machine_id, row.sr);
    const direction = ['IN', 'OUT', 'UNKNOWN'].includes(row.pun_flag) ? row.pun_flag : settings.directionMap?.[row.pun_flag] ?? raw?.direction ?? 'UNKNOWN';
    result.push({ id: appID(row.sr), timestamp: iso(time), direction, machine: row.machine_description ?? row.machine_model ?? 'Unassigned machine', branch: row.branch ?? '' });
  }
  return result;
}
