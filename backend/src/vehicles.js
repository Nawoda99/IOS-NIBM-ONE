import { Router } from 'express';
import { randomBytes } from 'node:crypto';
import { DateTime } from 'luxon';
import { HTTPError, required, iso, timestamp } from './rules.js';
import { appID, databaseID } from './identity.js';
import { hasPermission, permissionsFor, requirePermission } from './access.js';
import { employeeSelect } from './records.js';

const zone = 'Asia/Colombo';
const manages = user => hasPermission(user, 'vehicles.manage');
const canRead = (user, row) => manages(user) || user.id === row.requester_id || user.id === row.driver_id ||
  (user.id === row.supervisor_id && hasPermission(user, 'vehicles.recommend'));
const canTrack = (user, row) => manages(user) || user.id === row.requester_id || user.id === row.driver_id;
const requestSelect = `SELECT r.*,e.full_name AS requester_name,e.epf_no,s.full_name AS supervisor_name,
  d.full_name AS driver_name,v.plate,v.name AS vehicle_name FROM ios_vehicle_requests r
  JOIN employees e ON e.id=r.requester_id JOIN employees s ON s.id=r.supervisor_id
  LEFT JOIN employees d ON d.id=r.driver_id LEFT JOIN ios_company_vehicles v ON v.id=r.vehicle_id`;

export function vehicleRequestValue(row, user) {
  return { id: appID(row.id), number: 'VR-' + String(row.id).padStart(6, '0'), requesterID: appID(row.requester_id),
    requesterName: row.requester_name, epfNo: String(row.epf_no), supervisorID: appID(row.supervisor_id), supervisorName: row.supervisor_name,
    costCode: row.cost_code, placeToVisit: row.place_to_visit, dutyStatus: row.duty_status, requiredDate: row.required_date,
    outwardTime: row.outward_time.slice(0, 5), inwardTime: row.inward_time.slice(0, 5), status: row.status,
    vehicleID: row.vehicle_id ? appID(row.vehicle_id) : null, vehiclePlate: row.plate ?? null, vehicleName: row.vehicle_name ?? null,
    driverID: row.driver_id ? appID(row.driver_id) : null, driverName: row.driver_name ?? null, remarks: row.remarks,
    createdAt: iso(row.createdAt), startedAt: row.started_at ? iso(row.started_at) : null,
    sharingKey: user.id === row.driver_id && user.session_id === row.sharing_session_id && row.status === 'In progress' ? row.sharing_key : null };
}
async function readRequest(db, value, user) {
  const [row] = await db.query(requestSelect + ' WHERE r.id=?', [databaseID(value)]);
  if (!row || !canRead(user, row)) throw new HTTPError(404, 'Vehicle request not found.');
  return row;
}
export function vehicleSchedule(input, now = DateTime.now()) {
  const requiredDate = input.requiredDate, outward = input.outwardTime, inward = input.inwardTime;
  const date = typeof requiredDate === 'string' ? DateTime.fromISO(requiredDate, { zone }) : DateTime.invalid('Missing date');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(requiredDate ?? '') || !date.isValid || date.toISODate() !== requiredDate || requiredDate < now.setZone(zone).toISODate()) {
    throw new HTTPError(400, 'Choose today or a future required date.');
  }
  if (![outward, inward].every(value => typeof value === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(value)) || inward <= outward) {
    throw new HTTPError(400, 'Inward time must be later than outward time on the required date.');
  }
  return { requiredDate, outward, inward };
}
export function validateVehicleLocation(input, now = new Date()) {
  const { latitude, longitude, accuracy } = input;
  if (!Number.isFinite(latitude) || Math.abs(latitude) > 90 || !Number.isFinite(longitude) || Math.abs(longitude) > 180 ||
      !Number.isFinite(accuracy) || accuracy < 0 || accuracy > 200) throw new HTTPError(400, 'Send a valid GPS position with accuracy within 200 metres.');
  const captured = timestamp(input.capturedAt).toJSDate(), age = now - captured;
  if (age > 120000 || age < -30000) throw new HTTPError(400, 'Send a current GPS position.');
  if (typeof input.sharingKey !== 'string' || !/^[a-f0-9]{64}$/.test(input.sharingKey)) throw new HTTPError(403, 'Location sharing is not active on this device.');
  return { latitude, longitude, accuracy, captured };
}
function trackingValue(row, location) {
  if (row.status !== 'In progress' || !location) return { requestID: appID(row.id), status: row.status, location: null };
  return { requestID: appID(row.id), status: row.status, location: { coordinate: { latitude: location.latitude, longitude: location.longitude },
    accuracy: location.accuracy, capturedAt: iso(location.captured_at), receivedAt: iso(location.received_at), isSharing: Boolean(location.sharing && row.sharing_key) } };
}
export async function stopSessionVehicleSharing(db, sessionID) {
  await db.query(`UPDATE ios_vehicle_locations l JOIN ios_vehicle_requests r ON r.id=l.request_id SET l.sharing=0 WHERE r.sharing_session_id=?`, [sessionID]);
  await db.query('UPDATE ios_vehicle_requests SET sharing_key=NULL,sharing_session_id=NULL WHERE sharing_session_id=?', [sessionID]);
}

export function vehicleRouter(db) {
  const api = Router();
  async function directory(user) {
    const employees = await db.query(employeeSelect + ' WHERE COALESCE(e.status,1)=1 AND (c.expiry IS NULL OR c.expiry>UTC_TIMESTAMP()) ORDER BY e.full_name');
    const rolePermissions = new Map();
    const supervisors = [];
    for (const employee of employees) {
      if (!rolePermissions.has(employee.role)) rolePermissions.set(employee.role, await permissionsFor(db, employee.role));
      if (employee.id !== user.id && rolePermissions.get(employee.role).includes('vehicles.recommend')) supervisors.push(employee);
    }
    const person = row => ({ id: appID(row.id), name: row.name, epfNo: String(row.epf_no) });
    return { supervisors: supervisors.map(person), drivers: manages(user) ? employees.map(person) : [],
      vehicles: manages(user) ? (await db.query('SELECT id,plate,name,active FROM ios_company_vehicles WHERE active=1 ORDER BY plate')).map(row => ({ ...row, id: appID(row.id), active: Boolean(row.active) })) : [] };
  }
  api.get('/directory', async (req, res) => {
    if (!['vehicles.request', 'vehicles.recommend', 'vehicles.manage'].some(p => hasPermission(req.user, p))) throw new HTTPError(403, 'Vehicle request access is required.');
    res.json(await directory(req.user));
  });
  api.get('/requests', async (req, res) => {
    const user = req.user;
    if (!['vehicles.request', 'vehicles.recommend', 'vehicles.manage'].some(p => hasPermission(user, p))) throw new HTTPError(403, 'Vehicle request access is required.');
    const condition = manages(user) ? '1=1' : hasPermission(user, 'vehicles.recommend') ? '(r.requester_id=? OR r.supervisor_id=?)' : 'r.requester_id=?';
    const values = manages(user) ? [] : hasPermission(user, 'vehicles.recommend') ? [user.id, user.id] : [user.id];
    const rows = await db.query(requestSelect + ' WHERE ' + condition + ' ORDER BY r.createdAt DESC,r.id DESC LIMIT 200', values);
    res.json(rows.map(row => vehicleRequestValue(row, user)));
  });
  api.get('/driver-trips', async (req, res) => {
    const rows = await db.query(requestSelect + " WHERE r.driver_id=? AND r.status IN ('Assigned','In progress','Completed') ORDER BY r.required_date DESC,r.outward_time DESC LIMIT 100", [req.user.id]);
    res.json(rows.map(row => vehicleRequestValue(row, req.user)));
  });
  api.post('/requests', requirePermission('vehicles.request'), async (req, res) => {
    const input = req.body ?? {}, schedule = vehicleSchedule(input);
    const cost = required(input.costCode, 'cost code', 100), place = required(input.placeToVisit, 'place to be visited', 500), duty = required(input.dutyStatus, 'duty status', 500);
    const supervisorID = databaseID(input.supervisorID);
    if (!(await directory(req.user)).supervisors.some(person => databaseID(person.id) === supervisorID)) throw new HTTPError(400, 'Select an active recommendation person other than yourself.');
    const id = await db.transaction(async tx => {
      await tx.query('SELECT id FROM employees WHERE id=? FOR UPDATE', [req.user.id]);
      const overlaps = await tx.query(`SELECT id FROM ios_vehicle_requests WHERE requester_id=? AND required_date=?
        AND outward_time < ? AND inward_time > ? AND status NOT IN ('Rejected','Cancelled','Completed') FOR UPDATE`, [req.user.id, schedule.requiredDate, schedule.inward, schedule.outward]);
      if (overlaps.length) throw new HTTPError(409, 'You already have a vehicle request during this time.');
      const now = new Date();
      return (await tx.query(`INSERT INTO ios_vehicle_requests
        (requester_id,supervisor_id,cost_code,place_to_visit,duty_status,required_date,outward_time,inward_time,createdAt,updatedAt)
        VALUES (?,?,?,?,?,?,?,?,?,?)`, [req.user.id, supervisorID, cost, place, duty, schedule.requiredDate, schedule.outward, schedule.inward, now, now])).insertId;
    });
    res.status(201).json(vehicleRequestValue(await readRequest(db, appID(id), req.user), req.user));
  });
  api.get('/requests/:id', async (req, res) => res.json(vehicleRequestValue(await readRequest(db, req.params.id, req.user), req.user)));

  async function mutate(req, operation) {
    const id = databaseID(req.params.id);
    await db.transaction(async tx => {
      const [row] = await tx.query('SELECT * FROM ios_vehicle_requests WHERE id=? FOR UPDATE', [id]);
      if (!row || !canRead(req.user, row)) throw new HTTPError(404, 'Vehicle request not found.');
      await operation(tx, row, req.body ?? {});
    });
    return vehicleRequestValue(await readRequest(db, req.params.id, req.user), req.user);
  }
  api.post('/requests/:id/decision', async (req, res) => res.json(await mutate(req, async (tx, row, input) => {
    if (req.user.id === row.requester_id) throw new HTTPError(403, 'You cannot decide your own vehicle request.');
    if (typeof input.approve !== 'boolean') throw new HTTPError(400, 'Choose approval or rejection.');
    const recommending = row.status === 'Pending recommendation' && row.supervisor_id === req.user.id && hasPermission(req.user, 'vehicles.recommend');
    const approving = row.status === 'Pending approval' && manages(req.user);
    if (!recommending && !approving) throw new HTTPError(403, 'This request is not awaiting your decision.');
    const remarks = input.approve ? (input.remarks ? required(input.remarks, 'remarks', 500) : null) : required(input.remarks, 'rejection reason', 500);
    const status = input.approve ? recommending ? 'Pending approval' : 'Approved' : 'Rejected';
    await tx.query(`UPDATE ios_vehicle_requests SET status=?,remarks=?,${recommending ? 'recommended_at=?' : 'approved_at=?,approved_by=?'},updatedAt=? WHERE id=?`,
      [status, remarks, new Date(), ...(!recommending ? [req.user.id] : []), new Date(), row.id]);
  })));
  api.post('/requests/:id/cancel', async (req, res) => res.json(await mutate(req, async (tx, row) => {
    if (row.requester_id !== req.user.id && !manages(req.user)) throw new HTTPError(403, 'Only the requester or transport manager can cancel.');
    if (!['Pending recommendation', 'Pending approval', 'Approved', 'Assigned'].includes(row.status)) throw new HTTPError(409, 'This request can no longer be cancelled.');
    await tx.query("UPDATE ios_vehicle_requests SET status='Cancelled',sharing_key=NULL,sharing_session_id=NULL,updatedAt=? WHERE id=?", [new Date(), row.id]);
  })));
  api.post('/requests/:id/assign', requirePermission('vehicles.manage'), async (req, res) => res.json(await mutate(req, async (tx, row, input) => {
    if (!['Approved', 'Assigned'].includes(row.status)) throw new HTTPError(409, 'Approve this request before assigning a vehicle.');
    if (row.required_date < DateTime.now().setZone(zone).toISODate()) throw new HTTPError(409, 'The requested date has passed.');
    const vehicleID = databaseID(input.vehicleID), driverID = databaseID(input.driverID);
    const [vehicle] = await tx.query('SELECT id FROM ios_company_vehicles WHERE id=? AND active=1 FOR UPDATE', [vehicleID]);
    const [driver] = await tx.query(`SELECT e.id FROM employees e WHERE e.id=? AND COALESCE(e.status,1)=1
      AND EXISTS (SELECT 1 FROM user_credentials c WHERE c.employeeId=e.id AND (c.expiry IS NULL OR c.expiry>UTC_TIMESTAMP())) FOR UPDATE`, [driverID]);
    if (!vehicle || !driver) throw new HTTPError(400, 'Select an active company vehicle and driver with login access.');
    const overlaps = await tx.query(`SELECT id FROM ios_vehicle_requests WHERE id<>? AND (vehicle_id=? OR driver_id=?) AND
      ((required_date=? AND outward_time < ? AND inward_time > ? AND status='Assigned') OR status='In progress') FOR UPDATE`,
    [row.id, vehicleID, driverID, row.required_date, row.inward_time, row.outward_time]);
    if (overlaps.length) throw new HTTPError(409, 'This vehicle or driver is already assigned during that time or has an active trip.');
    await tx.query("UPDATE ios_vehicle_requests SET vehicle_id=?,driver_id=?,status='Assigned',updatedAt=? WHERE id=?", [vehicleID, driverID, new Date(), row.id]);
  })));
  api.post('/requests/:id/start', async (req, res) => res.json(await mutate(req, async (tx, row) => {
    if (row.driver_id !== req.user.id) throw new HTTPError(403, 'Only the assigned driver can start location sharing.');
    if (!['Assigned', 'In progress'].includes(row.status)) throw new HTTPError(409, 'This trip is not available to start.');
    if (row.status === 'Assigned' && row.required_date !== DateTime.now().setZone(zone).toISODate()) throw new HTTPError(409, 'Start this trip on its required date.');
    const [vehicle] = await tx.query('SELECT id FROM ios_company_vehicles WHERE id=? AND active=1 FOR UPDATE', [row.vehicle_id]);
    if (!vehicle) throw new HTTPError(409, 'This company vehicle is no longer active.');
    await tx.query('SELECT id FROM employees WHERE id=? FOR UPDATE', [row.driver_id]);
    const other = await tx.query("SELECT id FROM ios_vehicle_requests WHERE id<>? AND status='In progress' AND (vehicle_id=? OR driver_id=?) FOR UPDATE", [row.id, row.vehicle_id, row.driver_id]);
    if (other.length) throw new HTTPError(409, 'Finish the active trip before starting another one.');
    await tx.query("UPDATE ios_vehicle_requests SET status='In progress',started_at=COALESCE(started_at,?),sharing_key=?,sharing_session_id=?,updatedAt=? WHERE id=?",
      [new Date(), randomBytes(32).toString('hex'), req.user.session_id, new Date(), row.id]);
  })));
  api.post('/requests/:id/complete', async (req, res) => res.json(await mutate(req, async (tx, row) => {
    if (row.driver_id !== req.user.id && !manages(req.user)) throw new HTTPError(403, 'Only the assigned driver or transport manager can complete this trip.');
    if (row.status !== 'In progress') throw new HTTPError(409, 'Start the trip before completing it.');
    await tx.query("UPDATE ios_vehicle_requests SET status='Completed',completed_at=?,sharing_key=NULL,sharing_session_id=NULL,updatedAt=? WHERE id=?", [new Date(), new Date(), row.id]);
    await tx.query('UPDATE ios_vehicle_locations SET sharing=0 WHERE request_id=?', [row.id]);
  })));
  api.post('/requests/:id/pause', async (req, res) => {
    await mutate(req, async (tx, row, input) => {
      if (row.driver_id !== req.user.id || row.sharing_session_id !== req.user.session_id || !row.sharing_key || input.sharingKey !== row.sharing_key) throw new HTTPError(403, 'Sharing belongs to another driver session.');
      await tx.query('UPDATE ios_vehicle_requests SET sharing_key=NULL,sharing_session_id=NULL,updatedAt=? WHERE id=?', [new Date(), row.id]);
      await tx.query('UPDATE ios_vehicle_locations SET sharing=0 WHERE request_id=?', [row.id]);
    });
    res.json({ accepted: true });
  });
  api.post('/requests/:id/location', async (req, res) => {
    const input = req.body ?? {}, location = validateVehicleLocation(input);
    const accepted = await db.transaction(async tx => {
      const [row] = await tx.query('SELECT * FROM ios_vehicle_requests WHERE id=? FOR UPDATE', [databaseID(req.params.id)]);
      if (!row || row.driver_id !== req.user.id || row.sharing_session_id !== req.user.session_id || row.sharing_key !== input.sharingKey) throw new HTTPError(403, 'Only the sharing driver session can update this trip.');
      if (row.status !== 'In progress') throw new HTTPError(409, 'Location sharing has ended for this trip.');
      if (location.captured < new Date(row.started_at).getTime() - 5000) throw new HTTPError(400, 'This location predates the trip.');
      const [previous] = await tx.query('SELECT captured_at FROM ios_vehicle_locations WHERE request_id=?', [row.id]);
      if (previous && location.captured <= new Date(previous.captured_at)) return false;
      await tx.query(`INSERT INTO ios_vehicle_locations (request_id,latitude,longitude,accuracy,captured_at,received_at,sharing) VALUES (?,?,?,?,?,?,1)
        ON DUPLICATE KEY UPDATE latitude=VALUES(latitude),longitude=VALUES(longitude),accuracy=VALUES(accuracy),captured_at=VALUES(captured_at),received_at=VALUES(received_at),sharing=1`,
      [row.id, location.latitude, location.longitude, location.accuracy, location.captured, new Date()]);
      return true;
    });
    res.json({ accepted });
  });
  api.get('/requests/:id/tracking', async (req, res) => {
    const row = await readRequest(db, req.params.id, req.user);
    if (!canTrack(req.user, row)) throw new HTTPError(403, 'Vehicle location is visible only to the requester, driver and transport manager.');
    const [location] = row.status === 'In progress' ? await db.query('SELECT * FROM ios_vehicle_locations WHERE request_id=?', [row.id]) : [];
    res.json(trackingValue(row, location));
  });
  api.get('/fleet', requirePermission('vehicles.manage'), async (req, res) => {
    const vehicles = await db.query('SELECT id,plate,name,active FROM ios_company_vehicles ORDER BY plate');
    const rows = await db.query(requestSelect + " WHERE r.status='In progress'");
    const result = [];
    for (const vehicle of vehicles) {
      const trip = rows.find(row => row.vehicle_id === vehicle.id);
      const [location] = trip ? await db.query('SELECT * FROM ios_vehicle_locations WHERE request_id=?', [trip.id]) : [];
      result.push({ ...vehicle, id: appID(vehicle.id), active: Boolean(vehicle.active), trip: trip ? vehicleRequestValue(trip, req.user) : null, tracking: trip ? trackingValue(trip, location) : null });
    }
    res.json(result);
  });
  api.post('/fleet', requirePermission('vehicles.manage'), async (req, res) => {
    const plate = required(req.body?.plate, 'registration number', 32).toUpperCase(), name = required(req.body?.name, 'vehicle name', 120), now = new Date();
    let insertId;
    try { ({ insertId } = await db.query('INSERT INTO ios_company_vehicles (plate,name,createdAt,updatedAt) VALUES (?,?,?,?)', [plate, name, now, now])); }
    catch (error) {
      if (error.code === 'ER_DUP_ENTRY') throw new HTTPError(409, 'A company vehicle with this registration number already exists.');
      throw error;
    }
    res.status(201).json({ id: appID(insertId), plate, name, active: true });
  });
  return api;
}
