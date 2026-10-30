import { parseArgs } from 'node:util';
import bcrypt from 'bcryptjs';
import { loadEnvironment, loadConfig } from '../src/config.js';
import { database } from '../src/db.js';
import { epfNumber, required } from '../src/rules.js';
import { createEmployee } from '../src/records.js';

loadEnvironment();
const { values } = parseArgs({ options: { epf: { type: 'string' }, name: { type: 'string' }, identity: { type: 'string' }, role: { type: 'string', default: 'Employee' }, branch: { type: 'string', default: 'Colombo' } } });
let db;
try {
  const epf = epfNumber(values.epf), name = required(values.name, 'employee name', 200);
  if (!['Employee', 'Approver', 'Support'].includes(values.role)) throw new Error('Use Employee, Approver or Support for --role.');
  const password = process.env.NEW_EMPLOYEE_PASSWORD;
  if (!password || password.length < 8 || Buffer.byteLength(password) > 72) throw new Error('Set NEW_EMPLOYEE_PASSWORD privately in backend/.env (8+ characters, maximum 72 UTF-8 bytes).');
  const config = loadConfig();
  db = database(config.database);
  if ((await db.query('SELECT id FROM employees WHERE epf_no=?', [epf])).length) throw new Error('That EPF No. is already registered. Its account was preserved.');
  await createEmployee(db, { epfNo: epf, name, branch: required(values.branch, 'branch', 255), role: values.role, passwordHash: await bcrypt.hash(password, 12), identityNo: required(values.identity, 'identity number', 512) });
  console.log(`Registered EPF No. ${epf}. The password was not printed.`);
} catch (error) { console.error(error.code ? `Account creation failed (${error.code}).` : error.message); process.exitCode = 1; }
finally { if (db) await db.close(); }
