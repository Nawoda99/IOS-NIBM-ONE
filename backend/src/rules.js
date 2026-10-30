import { DateTime } from 'luxon';
import { createHash, randomUUID } from 'node:crypto';

export class HTTPError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export const iso = (date = new Date()) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');
export const hash = value => createHash('sha256').update(value).digest('hex');
export const parsePayload = row => JSON.parse(row.payload);
const profileText = value => value == null || String(value).trim() === '' ? null : String(value).trim();
function profileDate(value) {
  if (value == null) return null;
  // HR employment dates are calendar dates. Preserve the stored date without a phone timezone shift.
  const date = value instanceof Date ? DateTime.fromJSDate(value, { zone: 'UTC' }) : DateTime.fromISO(String(value).replace(' ', 'T'), { setZone: true });
  return date.isValid ? date.toISODate() : null;
}
export function profile(row) {
  return { id: row.id, epfNo: row.epf_no, name: row.name, branch: row.branch, role: row.role,
    details: {
      firstName: profileText(row.first_name), lastName: profileText(row.last_name), initials: profileText(row.initials),
      // Codes match the HRMS client's Title and Gender definitions; unknown codes stay unset.
      title: row.title == null ? null : ({ 1: 'Rev', 2: 'Prof', 3: 'Dr', 4: 'Mr', 5: 'Ms' }[row.title] ?? null),
      gender: row.gender == null ? null : ({ 0: 'Male', 1: 'Female' }[row.gender] ?? null),
      identityNumber: profileText(row.identity_no), passportNumber: profileText(row.passport_no),
      department: profileText(row.department_name), employmentType: profileText(row.employment_type_name),
      grade: profileText(row.grade_name) ?? profileText(row.grade_code),
      employmentStatus: row.status == null ? null : ({ 0: 'Inactive', 1: 'Active' }[row.status] ?? null),
      previousEPFNumber: profileText(row.old_epf_no), erpEmployeeID: profileText(row.circuito_emp_id),
      joinedDate: profileDate(row.joined_date), appointmentDate: profileDate(row.appointment_date),
      probationEndDate: profileDate(row.probation_end_date), assignmentStartDate: profileDate(row.assignment_start_date),
      officialEmail: profileText(row.official_email), personalEmail: profileText(row.personal_email),
      primaryMobile: profileText(row.mobile_no_1), secondaryMobile: profileText(row.mobile_no_2),
      primaryTelephone: profileText(row.tel_no_1), secondaryTelephone: profileText(row.tel_no_2),
      primaryAddress: profileText(row.address_1), secondaryAddress: profileText(row.address_2),
      emergencyContactName: profileText(row.immediate_contact_name), emergencyContactPhone: profileText(row.immediate_contact_tel_no),
      emergencyContactAddress: profileText(row.immediate_contact_address), emergencyContactRelationship: profileText(row.relationship)
    }
  };
}
export const entitlements = { Annual: 14, Casual: 5, Medical: 7, Special: 2 };
export const ticketStatuses = ['Open', 'Assigned', 'In Progress', 'Resolved', 'Closed'];
export function required(value, label, max = 4000) {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max) throw new HTTPError(400, `Enter a valid ${label} (maximum ${max} characters).`);
  return value.trim();
}
export function epfNumber(value) {
  const epf = required(value, 'EPF No.', 20);
  if (!/^\d{1,20}$/.test(epf)) throw new HTTPError(400, 'Enter the numeric EPF No. without a name or prefix.');
  return epf; // Keep it as a string: leading zeroes are significant.
}
export function uuid(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new HTTPError(400, 'Invalid record ID.');
  return value;
}
export function timestamp(value) {
  if (typeof value !== 'string' || !/T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value)) throw new HTTPError(400, 'Use a timestamp with an explicit timezone.');
  const date = DateTime.fromISO(value, { setZone: true });
  if (!date.isValid) throw new HTTPError(400, 'Invalid timestamp.');
  return date;
}
export function attachment(value) {
  if (value == null) return null;
  if (typeof value !== 'object') throw new HTTPError(400, 'Invalid attachment.');
  const name = required(value.name, 'attachment name', 240);
  if (typeof value.data !== 'string' || value.data.length > 10_666_668 || value.data.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(value.data)) throw new HTTPError(400, 'Invalid attachment data.');
  const decoded = Buffer.from(value.data, 'base64');
  if (decoded.toString('base64') !== value.data) throw new HTTPError(400, 'Invalid attachment data.');
  if (decoded.length > 8_000_000) throw new HTTPError(400, 'Attachments must be no larger than 8 MB.');
  return { id: value.id ? uuid(value.id) : randomUUID(), name, data: value.data };
}
export function leaveDays(input, existing, now = DateTime.now(), allowances = entitlements) {
  if (!Object.hasOwn(entitlements, input.type) || typeof input.halfDay !== 'boolean') throw new HTTPError(400, 'Invalid leave type or duration.');
  const start = timestamp(input.start).setZone('Asia/Colombo').startOf('day');
  const end = timestamp(input.end).setZone('Asia/Colombo').startOf('day');
  if (end < start || start.year !== end.year || (input.halfDay && start.toISODate() !== end.toISODate())) throw new HTTPError(400, 'Check the leave dates and half-day selection.');
  required(input.reason, 'leave reason'); attachment(input.attachment);
  const active = existing.filter(row => row.status !== 'Rejected');
  const used = active.filter(row => row.type === input.type && DateTime.fromISO(row.startDate).setZone('Asia/Colombo').year === start.year).reduce((total, row) => total + row.days, 0);
  const days = input.halfDay ? 0.5 : Math.round(end.diff(start, 'days').days) + 1;
  if (days > allowances[input.type] - used) throw new HTTPError(409, 'Insufficient leave balance.');
  if (active.some(row => start <= DateTime.fromISO(row.endDate).setZone('Asia/Colombo').startOf('day') && end >= DateTime.fromISO(row.startDate).setZone('Asia/Colombo').startOf('day'))) throw new HTTPError(409, 'These dates overlap an existing request.');
  return days;
}
export function normalisedPunch(input) {
  // Older clients may still send this alias; it represents the same EPF, never another identity.
  const epfNo = epfNumber(input.epfNo ?? input.deviceUserID);
  if (input.epfNo !== undefined && input.deviceUserID !== undefined && input.epfNo !== input.deviceUserID) throw new HTTPError(400, 'Conflicting EPF numbers.');
  const date = timestamp(input.timestamp).toJSDate();
  if (date < new Date('2000-01-01T00:00:00Z') || date > new Date(Date.now() + 86400000)) throw new HTTPError(400, 'Invalid machine timestamp. Check its clock and configured timezone.');
  if (!['IN', 'OUT', 'UNKNOWN'].includes(input.direction)) throw new HTTPError(400, 'Invalid punch direction.');
  for (const code of [input.rawStatus, input.rawPunch]) if (code != null && (!Number.isInteger(code) || code < 0 || code > 255)) throw new HTTPError(400, 'Invalid raw punch code.');
  return { epfNo, timestamp: iso(date), direction: input.direction, rawStatus: input.rawStatus ?? null, rawPunch: input.rawPunch ?? null,
    rawRecord: input.rawRecord ?? null };
}
