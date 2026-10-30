import { randomUUID } from 'node:crypto';
import { DateTime } from 'luxon';
import { entitlements, HTTPError, iso } from './rules.js';
import { appID, canonicalEPF, databaseID } from './identity.js';
import { saveLeaveAttachment, readLeaveAttachment } from './files.js';

export const statusToNative = { Open: 'new', Assigned: 'assigned', 'In Progress': 'in_progress', Resolved: 'resolved', Closed: 'closed' };
const statusToApp = { new: 'Open', assigned: 'Assigned', in_progress: 'In Progress', resolved: 'Resolved', closed: 'Closed', on_hold: 'In Progress', cancelled: 'Closed', supervisor_rejected: 'Closed', pending_supervisor_approval: 'Open' };
const roleCodes = { Employee: 'EMPLOYEE', Approver: 'APPROVER', Support: 'SUPPORT' };
const json = value => typeof value === 'string' ? JSON.parse(value) : value;
const details = value => { try { return json(value) ?? {}; } catch { return {}; } };

export async function ensureBranch(db, description) {
  const [existing] = await db.query('SELECT id FROM branch WHERE description=? ORDER BY id LIMIT 1', [description]);
  if (existing) return existing.id;
  return (await db.query('INSERT INTO branch (description,createdAt,updatedAt) VALUES (?,?,?)', [description, new Date(), new Date()])).insertId;
}
export async function ensureDepartment(db, description) {
  const [existing] = await db.query('SELECT id FROM department WHERE description=? ORDER BY id LIMIT 1', [description]);
  if (existing) return existing.id;
  return (await db.query('INSERT INTO department (description,ticketing_enabled,createdAt,updatedAt) VALUES (?,1,?,?)', [description, new Date(), new Date()])).insertId;
}
export async function ensureRole(db, role) {
  const [existing] = await db.query('SELECT id FROM system_roles WHERE code=? ORDER BY id LIMIT 1', [roleCodes[role]]);
  if (existing) return existing.id;
  return (await db.query('INSERT INTO system_roles (code,name,status,createdAt,updatedAt) VALUES (?,?,1,?,?)', [roleCodes[role], role, new Date(), new Date()])).insertId;
}
export async function createEmployee(db, { epfNo, name, branch, role, passwordHash, identityNo }) {
  const epf = canonicalEPF(epfNo);
  if (!identityNo) throw new HTTPError(400, 'The backup requires an actual identity number. Supply --identity when creating an employee.');
  return db.transaction(async tx => {
    const branchID = await ensureBranch(tx, branch), roleID = await ensureRole(tx, role);
    const parts = name.trim().split(/\s+/), now = new Date();
    const id = (await tx.query(`INSERT INTO employees
      (full_name,first_name,last_name,initials,epf_no,identity_no,status,branch_id,createdAt,updatedAt)
      VALUES (?,?,?,?,?,?,1,?,?,?)`, [name, parts[0], parts.slice(1).join(' '), parts.map(part => part[0]).join('.'), Number(epf), identityNo, branchID, now, now])).insertId;
    await tx.query('INSERT INTO user_credentials (username,password,lastUpdated,employeeId,createdAt,updatedAt) VALUES (?,?,?,?,?,?)', [epf, passwordHash, now, id, now, now]);
    await tx.query('INSERT INTO employee_system_roles (employee_id,role_id) VALUES (?,?)', [id, roleID]);
    return id;
  });
}
export const employeeSelect = `SELECT e.*,e.full_name AS name,b.description AS branch,c.password AS password_hash,
  CASE WHEN EXISTS (SELECT 1 FROM employee_system_roles er JOIN system_roles r ON r.id=er.role_id WHERE er.employee_id=e.id AND r.code='SUPPORT' AND COALESCE(r.status,1)=1) THEN 'Support'
    WHEN EXISTS (SELECT 1 FROM employee_system_roles er JOIN system_roles r ON r.id=er.role_id WHERE er.employee_id=e.id AND r.code='APPROVER' AND COALESCE(r.status,1)=1) THEN 'Approver' ELSE 'Employee' END AS role
  FROM employees e LEFT JOIN branch b ON b.id=e.branch_id JOIN user_credentials c ON c.employeeId=e.id`;
export async function seedLeaveTypes(db) {
  for (const name of Object.keys(entitlements)) {
    if (!(await db.query('SELECT id FROM leave_type WHERE name=?', [name])).length) await db.query(`INSERT INTO leave_type
      (name,duration_type,paid_leave,repeat_on_Every,createdAt,updatedAt) VALUES (?,1,1,'year',?,?)`, [name, new Date(), new Date()]);
  }
}
export async function ensureEligibility(db, employeeID, type, year) {
  const [leaveType] = await db.query('SELECT * FROM leave_type WHERE name=? AND active_state=1', [type]);
  if (!leaveType || !Object.hasOwn(entitlements, type)) throw new HTTPError(400, 'Invalid leave type.');
  const from = DateTime.fromObject({ year, month: 1, day: 1 }, { zone: 'Asia/Colombo' }).startOf('day');
  const to = from.endOf('year');
  let [row] = await db.query('SELECT * FROM eligible_leaves WHERE employee_id=? AND leave_type_id=? AND fromDate=? AND Status=1 ORDER BY id DESC LIMIT 1', [employeeID, leaveType.id, from.toJSDate()]);
  if (!row) {
    const id = (await db.query(`INSERT INTO eligible_leaves
      (fromDate,toDate,consumed_Count,eligible_Count,Status,description,employee_id,leave_type_id,createdAt,updatedAt)
      VALUES (?,?,0,?,1,?,?,?,?,?)`, [from.toJSDate(), to.toJSDate(), entitlements[type], `${type} ${year}`, employeeID, leaveType.id, new Date(), new Date()])).insertId;
    [row] = await db.query('SELECT * FROM eligible_leaves WHERE id=?', [id]);
  }
  return { ...row, eligible_count: row.eligible_Count };
}

async function leaveValue(db, row) {
  const [rejection] = await db.query(`SELECT r.remark FROM approval_action_remarks r JOIN approval_actions a ON a.id=r.approvalActionId
    JOIN approval_instance_steps s ON s.id=a.approvalInstanceStepId JOIN approval_request q ON q.approval_process_instance_id=s.approvalProcessInstanceId
    WHERE q.id=? AND a.action='REJECT' ORDER BY a.id DESC,r.id DESC LIMIT 1`, [row.approvalRequestId]);
  const start = DateTime.fromJSDate(row.request_start_date).setZone('Asia/Colombo').startOf('day');
  const end = DateTime.fromJSDate(row.request_end_date).setZone('Asia/Colombo').startOf('day');
  return { id: appID(row.id), type: row.type, startDate: iso(row.request_start_date), endDate: iso(row.request_end_date),
    days: row.leave_units == null ? Math.round(end.diff(start, 'days').days) + 1 : Number(row.leave_units), reason: row.reason,
    status: ['Pending', 'Approved', 'Rejected'][row.approval_status] ?? 'Pending', rejectionReason: rejection?.remark ?? null,
    attachment: await readLeaveAttachment(db, row.id), employeeName: row.employee_name, epfNo: String(row.epf_no) };
}
async function ticketValue(db, row) {
  const activities = await db.query('SELECT a.*,e.full_name AS author FROM ticket_activities a JOIN employees e ON e.id=a.actor_id WHERE a.ticket_id=? ORDER BY a.id', [row.id]);
  const metadata = activities.map(item => details(item.details)).find(item => item.kind === 'ticket_created')?.fields ?? {};
  const comments = activities.filter(item => details(item.details).kind === 'comment').map(item => ({ id: appID(item.id), author: item.author, text: details(item.details).text, createdAt: iso(item.createdAt) }));
  const events = activities.filter(item => details(item.details).kind !== 'comment' && statusToApp[item.to_status]).map(item => ({ id: appID(item.id), status: statusToApp[item.to_status], date: iso(item.createdAt) }));
  const [photo] = await db.query('SELECT * FROM ticket_attachments WHERE ticket_id=?', [row.id]);
  const [assignment] = await db.query('SELECT e.full_name FROM ticket_assignments a JOIN employees e ON e.id=a.employee_id WHERE a.ticket_id=? ORDER BY a.id DESC LIMIT 1', [row.id]);
  return { id: appID(row.id), number: row.ticket_number, title: row.title, description: row.description, category: row.category,
    room: metadata.room ?? '', assetID: metadata.assetID ?? '', priority: ['high', 'urgent'].includes(row.priority) ? 'High' : 'Normal', status: statusToApp[row.status] ?? 'Open',
    updatedAt: iso(row.updatedAt), coordinate: metadata.coordinate ?? null, assignedTo: assignment?.full_name ?? null,
    photo: photo ? { id: appID(photo.id), name: photo.original_name, data: photo.data.toString('base64') } : null, comments, events };
}
const queries = {
  leave: { sql: `SELECT r.*,r.employee_id AS owner_id,t.name AS type,e.full_name AS employee_name,e.epf_no FROM leave_requests r
    JOIN eligible_leaves l ON l.id=r.eligible_leave_id JOIN leave_type t ON t.id=l.leave_type_id JOIN employees e ON e.id=r.employee_id`, owner: 'r.employee_id' },
  ticket: { sql: 'SELECT r.*,r.requester_id AS owner_id,d.description AS category FROM tickets r JOIN department d ON d.id=r.department_id', owner: 'r.requester_id' },
  notice: { sql: 'SELECT r.*,r.employeeId AS owner_id FROM push_notification_outbox r', owner: 'r.employeeId' }
};
async function payload(db, kind, row) {
  if (kind === 'leave') return leaveValue(db, row);
  if (kind === 'ticket') return ticketValue(db, row);
  return { id: appID(row.id), title: row.title, date: iso(row.createdAt), isRead: row.readAt != null, destination: json(row.data)?.destination ?? { attendance: {} } };
}
export async function records(db, owner, kind, { excludeOwner = null } = {}) {
  const spec = queries[kind];
  const condition = owner != null ? `${spec.owner}=?` : excludeOwner != null ? `${spec.owner}<>?` : '1=1';
  const rows = await db.query(spec.sql + ' WHERE ' + condition + (kind === 'notice' ? ' AND r.dismissedAt IS NULL' : '') + ' ORDER BY r.createdAt DESC,r.id DESC', owner != null ? [owner] : excludeOwner != null ? [excludeOwner] : []);
  const result = [];
  for (const row of rows) result.push(await payload(db, kind, row));
  return result;
}
export async function findRecord(db, id, kind, { lock = false } = {}) {
  const [row] = await db.query(queries[kind].sql + ' WHERE r.id=?' + (lock ? ' FOR UPDATE' : ''), [databaseID(id)]);
  if (!row) return null;
  const value = await payload(db, kind, row);
  return { id: value.id, owner_id: row.owner_id, status: value.status, payload: JSON.stringify(value) };
}
export async function insertRecord(db, owner, kind, value) {
  const now = new Date();
  if (kind === 'leave') {
    const eligibility = await ensureEligibility(db, owner, value.type, DateTime.fromISO(value.startDate).setZone('Asia/Colombo').year);
    const process = (await db.query(`INSERT INTO approval_process_instances
      (processName,requestType,version,effectiveFromDate,isActive,createdBy,createdAt,updatedAt) VALUES (?,'leave',1,?,1,?,?,?)`, ['Leave approval', now, owner, now, now])).insertId;
    const role = await ensureRole(db, 'Approver');
    await db.query(`INSERT INTO approval_instance_steps (stepOrder,stepName,approverType,approverRoleId,approvalMode,requiredCount,approvalProcessInstanceId,createdAt,updatedAt)
      VALUES (1,?,'ROLE',?,'ANY',1,?,?,?)`, ['Approver decision', role, process, now, now]);
    const approval = (await db.query(`INSERT INTO approval_request (request_type,status,created_by,modified_by,created_at,modified_at,approval_process_instance_id)
      VALUES ('leave',0,?,?,?,?,?)`, [owner, owner, now, now, process])).insertId;
    const id = (await db.query(`INSERT INTO leave_requests
      (leave_Off_Type,employee_id,eligible_leave_id,approvalRequestId,request_start_date,request_end_date,reason,leave_units,createdAt,updatedAt)
      VALUES (?,?,?,?,?,?,?,?,?,?)`, [value.days === 0.5 ? 1 : 0, owner, eligibility.id, approval, new Date(value.startDate), new Date(value.endDate), value.reason, value.days, now, now])).insertId;
    value.id = appID(id);
    await saveLeaveAttachment(db, id, value.attachment);
  } else if (kind === 'ticket') {
    const department = await ensureDepartment(db, value.category);
    const id = (await db.query('INSERT INTO tickets (department_id,requester_id,title,description,priority,status,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?,?)',
      [department, owner, value.title, value.description, value.priority.toLowerCase(), 'new', now, now])).insertId;
    const number = 'NIBM-' + String(id).padStart(6, '0');
    await db.query('UPDATE tickets SET ticket_number=? WHERE id=?', [number, id]);
    await db.query(`INSERT INTO ticket_activities (ticket_id,actor_id,action,to_status,details,createdAt,updatedAt)
      VALUES (?,?,'created','new',?,?,?)`, [id, owner, JSON.stringify({ kind: 'ticket_created', fields: { room: value.room, assetID: value.assetID, coordinate: value.coordinate } }), now, now]);
    if (value.photo) {
      const bytes = Buffer.from(value.photo.data, 'base64');
      await db.query('INSERT INTO ticket_attachments (ticket_id,uploaded_by_id,original_name,content_type,size,data,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?,?)',
        [id, owner, value.photo.name, /\.png$/i.test(value.photo.name) ? 'image/png' : /\.jpe?g$/i.test(value.photo.name) ? 'image/jpeg' : 'application/octet-stream', bytes.length, bytes, now, now]);
    }
    const [row] = await db.query(queries.ticket.sql + ' WHERE r.id=?', [id]);
    Object.assign(value, await ticketValue(db, row));
  } else if (kind === 'notice') {
    const id = (await db.query(`INSERT INTO push_notification_outbox
      (employeeId,eventType,title,body,data,deduplicationKey,availableAt,createdAt,updatedAt) VALUES (?,?,?,?,?,?,?,?,?)`,
    [owner, Object.keys(value.destination)[0], value.title, value.title, JSON.stringify({ destination: value.destination }), randomUUID(), now, now, now])).insertId;
    value.id = appID(id);
  }
}
export async function replaceRecord(db, value, status = value.status ?? 'Read', actorID = null, assign = false) {
  const id = databaseID(value.id), now = new Date();
  if (value.startDate != null) {
    const [row] = await db.query('SELECT * FROM leave_requests WHERE id=?', [id]);
    const approval = status === 'Approved' ? 1 : 2;
    await db.query('UPDATE leave_requests SET approval_status=?,updatedAt=? WHERE id=?', [approval, now, id]);
    await db.query('UPDATE approval_request SET status=?,modified_by=?,modified_at=? WHERE id=?', [approval, actorID, now, row.approvalRequestId]);
    const [step] = await db.query('SELECT s.id FROM approval_instance_steps s JOIN approval_request r ON r.approval_process_instance_id=s.approvalProcessInstanceId WHERE r.id=? ORDER BY s.id LIMIT 1', [row.approvalRequestId]);
    const action = (await db.query('INSERT INTO approval_actions (approvalInstanceStepId,performedBy,action,actionDate,createdAt,updatedAt) VALUES (?,?,?,?,?,?)',
      [step.id, actorID, status === 'Approved' ? 'APPROVE' : 'REJECT', now, now, now])).insertId;
    if (value.rejectionReason) await db.query('INSERT INTO approval_action_remarks (approvalActionId,remark,createdBy,createdAt,updatedAt) VALUES (?,?,?,?,?)', [action, value.rejectionReason, actorID, now, now]);
    if (approval === 1) await db.query('UPDATE eligible_leaves SET consumed_Count=consumed_Count + ?,updatedAt=? WHERE id=?', [value.days, now, row.eligible_leave_id]);
  } else if (value.number != null) {
    const [row] = await db.query('SELECT * FROM tickets WHERE id=?', [id]);
    for (const comment of value.comments) {
      if (/^00000000-0000-4000-8000-/.test(comment.id)) continue;
      await db.query(`INSERT INTO ticket_activities (ticket_id,actor_id,action,from_status,to_status,details,createdAt,updatedAt)
        VALUES (?,?,'status_changed',?,?,?,?,?)`, [id, actorID, row.status, row.status, JSON.stringify({ kind: 'comment', text: comment.text }), now, now]);
    }
    if (assign) {
      const nativeStatus = statusToNative[status];
      await db.query('UPDATE tickets SET status=?,resolved_at=IF(?=\'resolved\',?,resolved_at),closed_at=IF(?=\'closed\',?,closed_at),updatedAt=? WHERE id=?', [nativeStatus, nativeStatus, now, nativeStatus, now, now, id]);
      if (!(await db.query('SELECT id FROM ticket_assignments WHERE ticket_id=? AND employee_id=?', [id, actorID])).length) await db.query('INSERT INTO ticket_assignments (ticket_id,employee_id,assigned_by_id,createdAt,updatedAt) VALUES (?,?,?,?,?)', [id, actorID, actorID, now, now]);
      await db.query(`INSERT INTO ticket_activities (ticket_id,actor_id,action,from_status,to_status,details,createdAt,updatedAt)
        VALUES (?,?,?,?,?,?,?,?)`, [id, actorID, nativeStatus === 'assigned' ? 'assigned' : 'status_changed', row.status, nativeStatus, JSON.stringify({ kind: 'status' }), now, now]);
    } else await db.query('UPDATE tickets SET updatedAt=? WHERE id=?', [now, id]);
    const [updated] = await db.query(queries.ticket.sql + ' WHERE r.id=?', [id]);
    Object.assign(value, await ticketValue(db, updated));
  } else await db.query('UPDATE push_notification_outbox SET readAt=?,updatedAt=? WHERE id=?', [value.isRead ? now : null, now, id]);
}
