import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import request from 'supertest';
import { DateTime } from 'luxon';
import { vehicleRouter, vehicleSchedule, validateVehicleLocation, vehicleRequestValue, stopSessionVehicleSharing } from '../src/vehicles.js';
import { appID } from '../src/identity.js';

const now = DateTime.fromISO('2026-10-30T09:00:00+05:30');
const schedule = { requiredDate: '2026-10-30', outwardTime: '09:00', inwardTime: '17:00' };
const key = 'ab'.repeat(32);
const baseRow = { id: 1, requester_id: 10, supervisor_id: 20, driver_id: 30, vehicle_id: 40, status: 'In progress',
  requester_name: 'Requester', supervisor_name: 'Supervisor', driver_name: 'Driver', epf_no: 1952,
  cost_code: 'CC-10', place_to_visit: 'Colombo', duty_status: 'Official meeting', required_date: '2026-10-30',
  outward_time: '09:00:00', inward_time: '17:00:00', plate: 'ABC-1234', vehicle_name: 'Company van', remarks: null,
  createdAt: new Date('2026-10-30T00:00:00Z'), started_at: new Date(Date.now() - 30000), sharing_key: key, sharing_session_id: 'driver-session' };
const actors = {
  owner: { id: 10, session_id: 'owner-session', permissions: ['vehicles.request'] },
  supervisor: { id: 20, session_id: 'supervisor-session', permissions: ['vehicles.recommend'] },
  driver: { id: 30, session_id: 'driver-session', permissions: [] },
  otherDriverSession: { id: 30, session_id: 'other-driver-session', permissions: [] },
  manager: { id: 50, session_id: 'manager-session', permissions: ['vehicles.manage'] },
  outsider: { id: 60, session_id: 'outsider-session', permissions: ['vehicles.request'] }
};
function harness(row = { ...baseRow }, existing = null) {
  const writes = [], state = { row, location: existing };
  const db = { transaction: async action => action(db), query: async (sql, values) => {
    if (sql.startsWith('SELECT * FROM ios_vehicle_requests') || sql.includes('FROM ios_vehicle_requests r')) return [state.row];
    if (sql.startsWith('SELECT * FROM ios_vehicle_locations')) return state.location ? [state.location] : [];
    if (sql.startsWith('SELECT captured_at')) return state.location ? [{ captured_at: state.location.captured_at }] : [];
    writes.push({ sql, values });
    if (sql.startsWith('INSERT INTO ios_vehicle_locations')) {
      state.location = { latitude: values[1], longitude: values[2], accuracy: values[3], captured_at: values[4], received_at: values[5], sharing: 1 };
    }
    if (sql.includes('SET sharing_key=NULL,sharing_session_id=NULL,updatedAt=')) { state.row.sharing_key = null; state.row.sharing_session_id = null; }
    if (sql.startsWith('UPDATE ios_vehicle_locations SET sharing=0') && state.location) state.location.sharing = 0;
    return {};
  } };
  const app = express(); app.use(express.json());
  app.use((req, _res, next) => { req.user = actors[req.headers.authorization]; if (!req.user) return next(Object.assign(Error('Sign in'), { status: 401 })); next(); });
  app.use('/vehicles', vehicleRouter(db));
  app.use((error, _req, res, _next) => res.status(error.status || 500).json({ reason: error.message }));
  return { app, db, writes, state };
}
const point = overrides => ({ latitude: 6.9271, longitude: 79.8612, accuracy: 12, capturedAt: new Date().toISOString(), sharingKey: key, ...overrides });

test('vehicle schedules require real dates, same-day increasing times and no past dates', () => {
  assert.deepEqual(vehicleSchedule(schedule, now), { requiredDate: '2026-10-30', outward: '09:00', inward: '17:00' });
  for (const patch of [{ requiredDate: '2026-02-30' }, { requiredDate: '2026-10-29' }, { outwardTime: '24:00' }, { inwardTime: '09:00' }, { outwardTime: '23:00', inwardTime: '01:00' }, { inwardTime: '17:00:00' }]) {
    assert.throws(() => vehicleSchedule({ ...schedule, ...patch }, now), error => error.status === 400);
  }
  assert.doesNotThrow(() => vehicleSchedule({ ...schedule, requiredDate: '2026-11-01' }, now));
});

test('GPS validation rejects bad coordinates, low accuracy, old/future timestamps and missing sharing consent', () => {
  assert.equal(validateVehicleLocation(point()).accuracy, 12);
  for (const patch of [{ latitude: 91 }, { longitude: -181 }, { latitude: '6.9' }, { accuracy: -1 }, { accuracy: 201 }, { capturedAt: new Date(Date.now() - 121000).toISOString() }, { capturedAt: new Date(Date.now() + 31000).toISOString() }]) {
    assert.throws(() => validateVehicleLocation(point(patch)), error => error.status === 400);
  }
  assert.throws(() => validateVehicleLocation(point({ sharingKey: '' })), error => error.status === 403);
});

test('request DTO discloses the upload key only to the active assigned driver session', () => {
  for (const name of ['owner', 'supervisor', 'manager', 'outsider', 'otherDriverSession']) assert.equal(vehicleRequestValue(baseRow, actors[name]).sharingKey, null);
  assert.equal(vehicleRequestValue(baseRow, actors.driver).sharingKey, key);
  assert.equal(vehicleRequestValue({ ...baseRow, status: 'Completed' }, actors.driver).sharingKey, null);
});

test('private tracking excludes unrelated employees and recommendation-only supervisors', async () => {
  const location = { latitude: 6.9271, longitude: 79.8612, accuracy: 12, captured_at: new Date(), received_at: new Date(), sharing: 1 };
  const { app } = harness(undefined, location), path = '/vehicles/requests/' + appID(1) + '/tracking';
  await request(app).get(path).expect(401);
  await request(app).get(path).set('Authorization', 'outsider').expect(404);
  await request(app).get(path).set('Authorization', 'supervisor').expect(403);
  for (const name of ['owner', 'driver', 'manager']) {
    const response = await request(app).get(path).set('Authorization', name).expect(200);
    assert.equal(response.body.location.coordinate.latitude, 6.9271);
  }
  const completed = harness({ ...baseRow, status: 'Completed' }, location);
  assert.equal((await request(completed.app).get(path).set('Authorization', 'owner')).body.location, null);
});

test('only the assigned sharing driver session can upload; old updates cannot overwrite a newer point', async () => {
  const { app, writes, state } = harness(), path = '/vehicles/requests/' + appID(1) + '/location';
  for (const name of ['owner', 'supervisor', 'manager', 'outsider', 'otherDriverSession']) await request(app).post(path).set('Authorization', name).send(point()).expect(403);
  assert.equal(writes.length, 0);
  const newest = point();
  await request(app).post(path).set('Authorization', 'driver').send(newest).expect(200);
  assert.equal(state.location.latitude, newest.latitude);
  const old = await request(app).post(path).set('Authorization', 'driver').send(point({ latitude: 7, capturedAt: new Date(Date.now() - 10000).toISOString() })).expect(200);
  assert.equal(old.body.accepted, false);
  assert.equal(state.location.latitude, newest.latitude);
});

test('stop sharing revokes the key so in-flight uploads and stale pause requests cannot restart or stop a new session', async () => {
  const { app, state } = harness(), path = '/vehicles/requests/' + appID(1);
  await request(app).post(path + '/location').set('Authorization', 'driver').send(point()).expect(200);
  await request(app).post(path + '/pause').set('Authorization', 'driver').send({ sharingKey: key }).expect(200);
  assert.equal(state.row.sharing_key, null);
  assert.equal(state.location.sharing, 0);
  await request(app).post(path + '/location').set('Authorization', 'driver').send(point()).expect(403);
  state.row.sharing_key = 'cd'.repeat(32); state.row.sharing_session_id = 'driver-session';
  await request(app).post(path + '/pause').set('Authorization', 'driver').send({ sharingKey: key }).expect(403);
  assert.equal(state.row.sharing_key, 'cd'.repeat(32));
});

test('decisions, dispatch and lifecycle actions reject wrong actors or stages before writes', async () => {
  const { app, writes } = harness({ ...baseRow, status: 'Pending recommendation' }), path = '/vehicles/requests/' + appID(1);
  await request(app).post(path + '/decision').set('Authorization', 'owner').send({ approve: true }).expect(403);
  await request(app).post(path + '/decision').set('Authorization', 'manager').send({ approve: true }).expect(403);
  await request(app).post(path + '/decision').set('Authorization', 'supervisor').send({ approve: false, remarks: '' }).expect(400);
  await request(app).post(path + '/assign').set('Authorization', 'owner').send({}).expect(403);
  await request(app).post(path + '/assign').set('Authorization', 'manager').send({}).expect(409);
  await request(app).post(path + '/start').set('Authorization', 'owner').expect(403);
  await request(app).post(path + '/start').set('Authorization', 'driver').expect(409);
  await request(app).post(path + '/complete').set('Authorization', 'driver').expect(409);
  await request(app).post(path + '/cancel').set('Authorization', 'supervisor').expect(403);
  assert.equal(writes.length, 0);
});

test('fleet details and management are restricted, while driver trips are scoped by authenticated employee', async () => {
  const { app, writes } = harness();
  for (const name of ['owner', 'driver', 'outsider', 'supervisor']) {
    await request(app).get('/vehicles/fleet').set('Authorization', name).expect(403);
    await request(app).post('/vehicles/fleet').set('Authorization', name).send({ plate: 'ABC-1', name: 'Van' }).expect(403);
  }
  assert.equal(writes.length, 0);
  const calls = [], db = { query: async (sql, values) => { calls.push({ sql, values }); return []; } };
  const driverApp = express();
  driverApp.use((req, _res, next) => { req.user = actors.driver; next(); });
  driverApp.use('/vehicles', vehicleRouter(db));
  await request(driverApp).get('/vehicles/driver-trips?driverID=10').expect(200);
  assert.match(calls[0].sql, /WHERE r.driver_id=\?/);
  assert.deepEqual(calls[0].values, [actors.driver.id]);
});

test('logout revokes only sharing owned by that login session', async () => {
  const calls = [];
  await stopSessionVehicleSharing({ query: async (sql, values) => { calls.push({ sql, values }); } }, 'driver-session');
  assert.equal(calls.length, 2);
  assert(calls.every(call => call.sql.includes('sharing_session_id=?') && call.values[0] === 'driver-session'));
});
