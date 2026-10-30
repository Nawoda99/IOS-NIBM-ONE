import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import bcrypt from 'bcryptjs';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { DateTime } from 'luxon';
import { HTTPError, iso, hash, profile, required, epfNumber, uuid, attachment, leaveDays, parsePayload, ticketStatuses, timestamp, entitlements } from './rules.js';
import { records, findRecord, insertRecord, replaceRecord, lockUser, notice, registerMachine, machineDetails, mapEmployee, importPunches, markFailure } from './store.js';
import { ensureEligibility, employeeSelect } from './records.js';
import { attendanceRecords, machineSelect, machineID, ATTENDANCE_SETTINGS } from './attendance.js';
import { appID, canonicalEPF } from './identity.js';
import { attendanceMonthRange, attendanceTimeZone, dailyAttendance } from './attendance-calendar.js';
import {appRoles,permissionCatalog,permissionsFor,hasPermission,requirePermission,requireAdministrator,savePermissions} from './access.js';
import {employeeAccounts,createAccount,updateAccount} from './administration.js';
import {branchDirectory,saveBranchLocation} from './branches.js';
import { registerPushDevice } from './push.js';
import { vehicleRouter, stopSessionVehicleSharing } from './vehicles.js';

const dummyPassword = bcrypt.hashSync('invalid-login-placeholder', 12);
const privileged = user => hasPermission(user,'machines.manage');
const remoteProfile = user => ({...profile({ ...user, id: appID(user.id), epf_no: String(user.epf_no), branch: user.branch ?? '' }),permissions:user.permissions??[]});

export function createApp({ db, config, deviceSync, pushEnabled = false }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use(express.json({ limit: '16mb' }));
  app.get('/health', async (_req, res) => { await db.query('SELECT COUNT(*) AS count FROM employees'); res.json({ status: 'ok', storage: 'mysql', backend: 'nodejs', fingerprint: 'node-zklib', machineSource: 'punch_machine' }); });

  app.post('/api/login', rateLimit({ windowMs: 15 * 60 * 1000, limit: 60, standardHeaders: 'draft-8', legacyHeaders: false,
    handler: (_req, res) => res.status(429).json({ error: true, reason: 'Too many sign-in attempts. Try again later.' }) }), async (req, res) => {
    const epfNo = canonicalEPF(req.body?.epfNo);
    const password = typeof req.body?.password === 'string' ? req.body.password : '';
    const [user] = await db.query(employeeSelect + ' WHERE e.epf_no=? AND COALESCE(e.status,1)=1 AND (c.expiry IS NULL OR c.expiry>UTC_TIMESTAMP())', [Number(epfNo)]);
    const matched = await bcrypt.compare(password, user?.password_hash || dummyPassword);
    if (!user || !matched || !password || Buffer.byteLength(password) > 72) throw new HTTPError(401, 'The EPF No. or password is incorrect.');
    user.permissions=await permissionsFor(db,user.role);
    const token = randomBytes(32).toString('hex');
    const now = new Date();
    await db.query('INSERT INTO login_devices (id,employeeId,sessionId,deviceType,deviceName,lastSeenAt,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?,?)', [randomUUID(), user.id, hash(token), 'IOS', 'NIBM ONE', now, now, now]);
    res.json({ token, profile: remoteProfile(user) });
  });

  const api = express.Router();
  api.use(async (req, _res, next) => {
    const token = /^Bearer ([^\s]+)$/i.exec(req.headers.authorization || '')?.[1];
    if (!token || token.length > 256) throw new HTTPError(401, 'Your session has expired. Sign in again.');
    const [user] = await db.query(employeeSelect.replace('SELECT e.*', 'SELECT e.*,s.id AS session_id') + ` JOIN login_devices s ON s.employeeId=e.id
      WHERE s.sessionId=? AND s.signedOutAt IS NULL AND s.createdAt>DATE_SUB(UTC_TIMESTAMP(),INTERVAL 8 HOUR)
        AND COALESCE(e.status,1)=1 AND (c.expiry IS NULL OR c.expiry>UTC_TIMESTAMP())`, [hash(token)]);
    if (!user) throw new HTTPError(401, 'Your session has expired. Sign in again.');
    if (!/^\d{1,20}$/.test(user.epf_no)) throw new HTTPError(401, 'Your account needs its actual EPF No. registered by an administrator.');
    user.permissions=await permissionsFor(db,user.role);
    req.user = user; next();
  });
  app.use('/api', api);
  api.use('/vehicles', vehicleRouter(db));
  api.get('/attendance', requirePermission('attendance.view'), async (req, res) => {
    const range = attendanceMonthRange(req.query.month);
    const punches = await attendanceRecords(db, String(req.user.epf_no), range.start, ATTENDANCE_SETTINGS, range.end);
    res.json({ month: range.month, timeZone: attendanceTimeZone, method: 'first-last', punches, days: dailyAttendance(punches) });
  });
  api.get('/push/status', (_req, res) => res.json({ enabled: pushEnabled }));
  api.put('/push/device', async (req, res) => {
    await registerPushDevice(db, req.user, req.body); res.sendStatus(204);
  });
  api.delete('/push/device', async (req, res) => {
    await db.query('DELETE FROM ios_push_devices WHERE sessionId=?', [req.user.session_id]); res.sendStatus(204);
  });
  api.post('/logout', async (req, res) => {
    await db.transaction(async tx => {
      await tx.query('UPDATE login_devices SET signedOutAt=?,updatedAt=? WHERE id=?', [new Date(), new Date(), req.user.session_id]);
      await tx.query('DELETE FROM ios_push_devices WHERE sessionId=?', [req.user.session_id]);
      await stopSessionVehicleSharing(tx, req.user.session_id);
    });
    res.sendStatus(204);
  });
  api.get('/snapshot', async (req, res) => {
    const user = req.user;
    const snapshot = await db.transaction(async tx => {
      const leaveRequests = hasPermission(user,'leave.view') ? await records(tx, user.id, 'leave') : [];
      const tickets = hasPermission(user,'tickets.view') ? await records(tx, hasPermission(user,'tickets.manage') ? null : user.id, 'ticket') : [];
      const notices = await records(tx, user.id, 'notice');
      const approvals = hasPermission(user,'leave.approve') ? await records(tx, null, 'leave', { excludeOwner: user.id }) : [];
      const currentMonth = attendanceMonthRange(undefined);
      const punches = hasPermission(user,'attendance.view') ? await attendanceRecords(tx, String(user.epf_no), currentMonth.start, ATTENDANCE_SETTINGS, currentMonth.end) : [];
      const sync = (hasPermission(user,'attendance.view') ? await tx.query(machineSelect + ' WHERE m.id IN (SELECT p.pun_machine_id FROM punches p WHERE p.emp_epf_no=?) ORDER BY m.id', [user.epf_no]) : [])
        .map(row => ({ code: row.code ?? 'machine-' + row.id, name: row.machine_description ?? row.machine_model, lastSyncedAt: row.last_synced_at ? iso(row.last_synced_at) : null, lastError: row.last_sync_status === 'FAILED' ? row.last_sync_message : null }));
      return { profile: remoteProfile(user), state: { leaveRequests, tickets, notices }, approvals, punches, sync };
    });
    res.json(snapshot);
  });

  api.post('/leave', requirePermission('leave.apply'), async (req, res) => {
    const input = req.body || {}, user = req.user;
    const value = await db.transaction(async tx => {
      await lockUser(tx, user.id);
      const year = timestamp(input.start).setZone('Asia/Colombo').year;
      const eligibility = await ensureEligibility(tx, user.id, input.type, year);
      const days = leaveDays(input, await records(tx, user.id, 'leave'), DateTime.now(), { ...entitlements, [input.type]: Number(eligibility.eligible_count) });
      const request = { id: randomUUID(), type: input.type, startDate: iso(new Date(input.start)), endDate: iso(new Date(input.end)), days,
        reason: required(input.reason, 'leave reason', 255), status: 'Pending', rejectionReason: null, attachment: attachment(input.attachment), employeeName: user.name, epfNo: String(user.epf_no) };
      await insertRecord(tx, user.id, 'leave', request);
      return request;
    });
    res.json(value);
  });
  api.post('/leave/:id/decision', requirePermission('leave.approve'), async (req, res) => {
    const id = uuid(req.params.id), input = req.body || {};
    if (typeof input.approve !== 'boolean') throw new HTTPError(400, 'Specify approval or rejection.');
    const original = await findRecord(db, id, 'leave');
    if (!original) throw new HTTPError(404, 'Leave request not found.');
    if (original.owner_id === req.user.id) throw new HTTPError(403, 'You cannot decide your own leave request.');
    const value = await db.transaction(async tx => {
      await lockUser(tx, original.owner_id);
      const row = await findRecord(tx, id, 'leave', { lock: true });
      if (row.status !== 'Pending') throw new HTTPError(409, 'This request is no longer pending.');
      const request = parsePayload(row);
      request.status = input.approve ? 'Approved' : 'Rejected';
      request.rejectionReason = input.approve ? null : required(input.reason, 'rejection reason');
      await replaceRecord(tx, request, request.status, req.user.id);
      await notice(tx, row.owner_id, `Leave request ${request.status.toLowerCase()}`, 'leave', id);
      return request;
    });
    res.json(value);
  });

  api.post('/tickets', requirePermission('tickets.create'), async (req, res) => {
    const input = req.body || {};
    const title = required(input.title, 'title', 160), description = required(input.description, 'description'), room = required(input.room, 'room', 200);
    if (!['IT', 'Network', 'Air conditioning', 'Electrical', 'Projector', 'Furniture', 'Maintenance', 'Other'].includes(input.category) || !['Normal', 'High'].includes(input.priority)) throw new HTTPError(400, 'Invalid category or priority.');
    let coordinate = null;
    if (input.coordinate != null) {
      const { latitude, longitude } = input.coordinate;
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) throw new HTTPError(400, 'Invalid coordinate.');
      coordinate = { latitude, longitude };
    }
    const photo = attachment(input.photo);
    const value = await db.transaction(async tx => {
      const ticket = { id: randomUUID(), number: '', title, description, category: input.category, room,
        assetID: typeof input.assetID === 'string' ? input.assetID.slice(0, 200) : '', priority: input.priority, status: 'Open', updatedAt: iso(),
        coordinate, photo, comments: [], events: [{ id: randomUUID(), status: 'Open', date: iso() }], assignedTo: null };
      await insertRecord(tx, req.user.id, 'ticket', ticket, ticket.status, ticket.number);
      return ticket;
    });
    res.json(value);
  });
  async function mutateTicket(req, change, assign = false) {
    const id = uuid(req.params.id);
    const original = await findRecord(db, id, 'ticket');
    if (!original || (original.owner_id !== req.user.id && !hasPermission(req.user,'tickets.manage'))) throw new HTTPError(404, 'Ticket not found.');
    return db.transaction(async tx => {
      await lockUser(tx, original.owner_id);
      const row = await findRecord(tx, id, 'ticket', { lock: true });
      const ticket = parsePayload(row);
      change(ticket); ticket.updatedAt = iso();
      await replaceRecord(tx, ticket, ticket.status, req.user.id, assign);
      await notice(tx, row.owner_id, `Ticket ${ticket.number} updated`, 'ticket', id);
      return ticket;
    });
  }
  api.post('/tickets/:id/comments', requirePermission('tickets.view'), async (req, res) => {
    const text = required(req.body?.text, 'comment');
    res.json(await mutateTicket(req, ticket => ticket.comments.push({ id: randomUUID(), author: req.user.name, text, createdAt: iso() })));
  });
  api.post('/tickets/:id/advance', requirePermission('tickets.manage'), async (req, res) => {
    res.json(await mutateTicket(req, ticket => {
      const index = ticketStatuses.indexOf(ticket.status);
      if (index < 0 || index + 1 >= ticketStatuses.length) throw new HTTPError(409, 'The ticket is already closed.');
      ticket.status = ticketStatuses[index + 1]; ticket.assignedTo = req.user.name;
      ticket.events.push({ id: randomUUID(), status: ticket.status, date: iso() });
    }, true));
  });
  api.post('/notices/:id/read', async (req, res) => {
    const id = uuid(req.params.id);
    await db.transaction(async tx => {
      const row = await findRecord(tx, id, 'notice', { lock: true });
      if (!row || row.owner_id !== req.user.id) throw new HTTPError(404, 'Notification not found.');
      const value = parsePayload(row); value.isRead = true; await replaceRecord(tx, value, 'Read');
    });
    res.sendStatus(204);
  });

  api.get('/machines', async (req, res) => {
    if (!privileged(req.user)) throw new HTTPError(403, 'Approver or support access is required.');
    const rows = await db.query(machineSelect);
    // Add counts separately to avoid changing the exact backup table.
    for (const row of rows) {
      const [counts] = await db.query('SELECT COUNT(*) AS total,SUM(e.id IS NULL) AS unmapped FROM punches p LEFT JOIN employees e ON e.epf_no=p.emp_epf_no WHERE p.pun_machine_id=?', [row.id]);
      Object.assign(row, counts);
    }
    res.json(rows.map(row => ({ ...machineDetails(row), total: Number(row.total), unmapped: row.total ? Number(row.unmapped) : 0 })));
  });
  api.post('/machines/sync', async (req, res) => {
    if (!privileged(req.user)) throw new HTTPError(403, 'Approver or support access is required.');
    if (!deviceSync) throw new HTTPError(503, 'The machine reader is not configured.');
    res.json(await deviceSync.sync(req.body?.machineID));
  });
  api.get('/machines/unmapped', async (req, res) => {
    if (!privileged(req.user)) throw new HTTPError(403, 'Approver or support access is required.');
    const selected = req.query.machineID == null ? null : machineID(req.query.machineID);
    const rows = await db.query(`SELECT p.emp_epf_no AS epf_no,COUNT(*) AS count FROM punches p LEFT JOIN employees e ON e.epf_no=p.emp_epf_no
      WHERE e.id IS NULL${selected == null ? '' : ' AND p.pun_machine_id=?'} GROUP BY p.emp_epf_no ORDER BY epf_no`, selected == null ? [] : [selected]);
    res.json(rows.map(row => ({ epfNo: String(row.epf_no), count: Number(row.count) })));
  });
  api.post('/machines/map', async (req, res) => {
    if (!privileged(req.user)) throw new HTTPError(403, 'Approver or support access is required.');
    await mapEmployee(db, req.body?.machineID, req.body || {}); res.sendStatus(204);
  });

  api.get('/branches',async(req,res)=>{
    if(!hasPermission(req.user,'map.view')&&req.user.role!=='Administrator')throw new HTTPError(403,'Map access is required.');
    res.json(await branchDirectory(db));
  });
  api.use('/admin',requireAdministrator);
  api.get('/admin/employees',async(req,res)=>res.json(await employeeAccounts(db,req.query.search,req.query.available==='true')));
  api.post('/admin/employees',async(req,res)=>res.status(201).json(await createAccount(db,req.body??{},req.user.id)));
  api.patch('/admin/employees/:id',async(req,res)=>{
    await updateAccount(db,req.params.id,req.body??{},req.user.id);res.sendStatus(204);
  });
  api.get('/admin/permissions',async(_req,res)=>res.json({permissions:permissionCatalog,roles:await Promise.all(appRoles.map(async role=>({role,permissions:await permissionsFor(db,role)})))}));
  api.put('/admin/permissions/:role',async(req,res)=>res.json({role:req.params.role,permissions:await savePermissions(db,req.params.role,req.body?.permissions)}));
  api.put('/admin/branches/:id/location',async(req,res)=>{
    await saveBranchLocation(db,req.params.id,req.body??{});res.sendStatus(204);
  });

  const integrations = express.Router();
  integrations.use((req, _res, next) => {
    const expected = config.ingestKey, supplied = req.get('X-Ingest-Key') || '';
    if (!expected || !timingSafeEqual(Buffer.from(hash(expected), 'hex'), Buffer.from(hash(supplied), 'hex'))) throw new HTTPError(401, 'Invalid integration key.');
    next();
  });
  app.use('/integrations', integrations);
  integrations.post('/machines', async (req, res) => {
    const row = await registerMachine(db, req.body || {});
    res.json(machineDetails(row));
  });
  integrations.post('/machines/:code/mappings', async (req, res) => {
    await mapEmployee(db, req.params.code, req.body || {}); res.sendStatus(204);
  });
  integrations.post('/machines/:code/punches', async (req, res) => {
    if (typeof req.body?.complete !== 'boolean') throw new HTTPError(400, 'Specify whether the full pull is complete.');
    res.json(await importPunches(db, req.params.code, req.body.records, req.body.complete, ATTENDANCE_SETTINGS));
  });
  integrations.post('/machines/:code/failure', async (req, res) => { await markFailure(db, req.params.code, required(req.body?.message, 'sync error', 250)); res.sendStatus(204); });

  app.use((_req, _res, next) => next(new HTTPError(404, 'Endpoint not found.')));
  app.use((error, _req, res, _next) => {
    let status = error.status || 500;
    if (error.type === 'entity.too.large') status = 413;
    if (error.code === 'ER_DUP_ENTRY') status = 409;
    const reason = error.code === 'ER_DUP_ENTRY' ? 'That EPF, identity or login name is already registered.' : status < 500 || error instanceof HTTPError ? error.message : 'Database operation failed. Check the server configuration and logs.';
    if (status >= 500 && !(error instanceof HTTPError)) console.error('Request failed:', error.code || error.constructor.name);
    res.status(status).json({ error: true, reason });
  });
  return app;
}
