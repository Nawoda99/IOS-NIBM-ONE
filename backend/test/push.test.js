import test from 'node:test';
import assert from 'node:assert/strict';
import request from 'supertest';
import { createServer, connect } from 'node:http2';
import { generateKeyPairSync, verify, randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/app.js';
import { importPunches } from '../src/attendance.js';
import { createAPNsSender, createPushWorker, enqueuePunchNotification, registerPushDevice } from '../src/push.js';
import { appID } from '../src/identity.js';

const token = 'ab'.repeat(32);
const namespace = 'push_unit_' + randomUUID().replaceAll('-', '');
const employee = { id: 7, session_id: 'session-a', epf_no: '1952', role: 'Employee' };
const machine = { id: 1, companyId: 1, machine_model: 'T900', branch: 'Colombo' };

test('device registration requires authentication, validates input, and binds ownership to the authenticated session', async () => {
  const calls = [];
  const db = { sequelize: { config: { database: namespace } }, query: async (sql, values) => {
    if (sql.includes('JOIN login_devices')) return [employee];
    calls.push({ sql, values });
    return sql.startsWith('SELECT') ? [{ id: employee.session_id }] : {};
  }, transaction: async action => action(db) };
  const app = createApp({ db, config: {} });
  assert.equal((await request(app).put('/api/push/device').send({ token, environment: 'sandbox' })).status, 401);
  assert.equal((await request(app).put('/api/push/device').set('Authorization', 'Bearer test').send({ token: '../invalid', environment: 'sandbox' })).status, 400);
  assert.equal((await request(app).put('/api/push/device').set('Authorization', 'Bearer test').send({ token, environment: 'invalid' })).status, 400);
  assert.equal((await request(app).put('/api/push/device').set('Authorization', 'Bearer test').send({ token: token.toUpperCase(), environment: 'sandbox', employeeId: 999 })).status, 204);
  const insert = calls.find(row => row.sql.startsWith('INSERT'));
  assert.deepEqual(insert.values.slice(0, 4), [token, 'sandbox', employee.id, employee.session_id]);
  assert.match(insert.sql, /ON DUPLICATE KEY UPDATE/);
  await request(app).post('/api/logout').set('Authorization', 'Bearer test').expect(204);
  assert(calls.some(row => row.sql.startsWith('DELETE FROM ios_push_devices WHERE sessionId=') && row.values[0] === employee.session_id));
  assert.equal((await request(app).get('/api/push/status').set('Authorization', 'Bearer test')).body.enabled, false);
  await assert.rejects(registerPushDevice({ transaction: async action => action({ query: async () => [] }) }, employee, { token, environment: 'sandbox' }), error => error.status === 401);
});

test('punch import queues only new, mapped punches; repeated sync and other EPFs do not alert', async () => {
  let inserted = false;
  const notices = [];
  const db = { sequelize: { config: { database: namespace } }, query: async (sql, values) => {
    if (sql.includes('JOIN companybranch')) return [machine];
    if (sql.startsWith('SELECT sr')) return inserted ? [{ sr: 101 }] : [];
    if (sql.startsWith('INSERT INTO punches')) { inserted = true; return { insertId: 101 }; }
    if (sql.startsWith('SELECT id FROM employees')) return values[0] === 1952 ? [{ id: employee.id }] : [];
    if (sql.startsWith('INSERT INTO push_notification_outbox')) { notices.push(values); return { insertId: 22 }; }
    if (sql.startsWith('UPDATE punch_machine')) return {};
    throw Error('Unexpected SQL: ' + sql);
  }, transaction: async action => action(db) };
  const punch = { epfNo: '1952', timestamp: new Date().toISOString(), direction: 'IN' };
  assert.equal((await importPunches(db, 'machine-1', [punch])).inserted, 1);
  assert.equal((await importPunches(db, 'machine-1', [punch])).duplicates, 1);
  assert.equal(notices.length, 1);
  assert.equal(notices[0][0], employee.id);
  assert.equal(notices[0][1], 'Punch IN recorded');
  assert.deepEqual(JSON.parse(notices[0][3]).destination, { attendance: {} });
  inserted = false;
  assert.equal((await importPunches(db, 'machine-1', [{ ...punch, epfNo: '9999' }])).unmapped, 1);
  assert.equal(notices.length, 1);
});

test('historical imports and future clocks do not create alerts; unknown directions are not guessed', async () => {
  const notices = [], now = new Date('2026-10-30T03:00:00Z');
  const db = { query: async (_sql, values) => notices.push(values) };
  for (const timestamp of ['2026-10-01T03:00:00Z', '2026-10-30T03:02:00Z']) {
    await enqueuePunchNotification(db, 7, 101, { timestamp, direction: 'IN' }, machine, now);
  }
  assert.equal(notices.length, 0);
  await enqueuePunchNotification(db, 7, 102, { timestamp: now.toISOString(), direction: 'UNKNOWN' }, machine, now);
  assert.equal(notices[0][1], 'Attendance punch recorded');
  assert.match(notices[0][2], /08:30/);
  assert.equal(notices[0][4], 'attendance:punch:102');
});

function deliveryStore(devices) {
  let current = new Date('2026-10-30T03:00:00Z');
  const row = { id: 123, employeeId: 7, eventType: 'attendance', title: 'Punch IN recorded', body: '08:30 · Colombo',
    data: { destination: { attendance: {} } }, deduplicationKey: 'attendance:punch:101', status: 'PENDING', attempts: 0, createdAt: current, availableAt: current };
  const db = { query: async (sql, values) => {
    if (sql.startsWith('SELECT * FROM push_notification_outbox')) return row.status === 'PENDING' && row.availableAt <= current ? [{ ...row, data: structuredClone(row.data) }] : [];
    if (sql.includes("SET status='PROCESSING'")) { row.status = 'PROCESSING'; row.attempts++; return {}; }
    if (sql.startsWith('SELECT d.*')) return [...devices];
    if (sql.startsWith('UPDATE push_notification_outbox SET data=')) { row.data = JSON.parse(values[0]); return {}; }
    if (sql.startsWith('DELETE FROM ios_push_devices')) { devices.splice(devices.findIndex(d => d.token === values[0]), 1); return {}; }
    if (sql.startsWith('UPDATE push_notification_outbox SET status=')) {
      [row.status, row.availableAt, row.processedAt, row.lastError] = values; return {};
    }
    throw Error('Unexpected SQL: ' + sql);
  }, transaction: async action => action(db) };
  return { db, row, now: () => current, advance: milliseconds => { current = new Date(current.getTime() + milliseconds); } };
}

test('retry persists successful devices, removes invalid tokens, and sends only the failed device again', async () => {
  const devices = [token, 'cd'.repeat(32), 'ef'.repeat(32)].map(token => ({ token, environment: 'sandbox', updatedAt: new Date() }));
  const store = deliveryStore(devices), calls = [];
  let retry = false;
  const sender = { enabled: true, close() {}, send: async device => {
    calls.push(device.token);
    if (device.token.startsWith('ef')) return { status: 410, reason: 'Unregistered' };
    if (device.token.startsWith('cd') && !retry) return { status: 503, reason: 'ServiceUnavailable' };
    return { status: 200 };
  } };
  const worker = createPushWorker(store.db, sender, { now: store.now });
  await worker.poll();
  assert.equal(store.row.status, 'PENDING');
  assert.equal(devices.length, 2);
  assert.equal(store.row.attempts, 1);
  retry = true; store.advance(6000);
  await worker.poll();
  assert.equal(store.row.status, 'SENT');
  assert.deepEqual(calls, [token, 'cd'.repeat(32), 'ef'.repeat(32), 'cd'.repeat(32)]);
  await worker.stop();
});

test('alerts without devices expire and disabled APNs makes no database calls', async () => {
  const store = deliveryStore([]);
  const worker = createPushWorker(store.db, { enabled: true, close() {}, send: async () => ({ status: 200 }) }, { now: store.now });
  await worker.poll(); assert.equal(store.row.status, 'PENDING');
  store.advance(16 * 60000);
  await worker.poll(); assert.equal(store.row.status, 'FAILED');
  assert.equal(store.row.lastError, 'Punch alert expired.');
  await worker.stop();
  const disabled = createPushWorker({ transaction: () => { throw Error('Should not query'); } }, createAPNsSender({}));
  await disabled.poll(); await disabled.stop();
});

test('a phone registering during retry receives the pending punch; repeated failures stop after eight attempts', async () => {
  const devices = [], store = deliveryStore(devices);
  let deliveries = 0;
  const sender = { enabled: true, close() {}, send: async () => { deliveries++; return { status: 200 }; } };
  const worker = createPushWorker(store.db, sender, { now: store.now });
  await worker.poll();
  devices.push({ token, environment: 'sandbox', updatedAt: store.now() });
  store.advance(6000); await worker.poll();
  assert.equal(store.row.status, 'SENT'); assert.equal(deliveries, 1);
  await worker.stop();

  const failed = deliveryStore([{ token, environment: 'sandbox', updatedAt: store.now() }]);
  const retries = createPushWorker(failed.db, { enabled: true, close() {}, send: async () => ({ status: 403, reason: 'InvalidProviderToken' }) }, { now: failed.now });
  for (let attempt = 0; attempt < 8; attempt++) { await retries.poll(); failed.advance(Math.min(300, 5 * 2 ** attempt) * 1000 + 1); }
  assert.equal(failed.row.status, 'FAILED'); assert.equal(failed.row.attempts, 8);
  await retries.stop();
});

test.after(async () => {
  const root = resolve(fileURLToPath(new URL('../storage', import.meta.url))), target = resolve(root, namespace);
  if (!target.startsWith(root + sep) || !/^push_unit_[a-f0-9]{32}$/.test(namespace)) throw Error('Unexpected cleanup path');
  await rm(target, { recursive: true, force: true });
});

test('APNs uses HTTP/2, ES256 credentials, the signed environment, alert headers, and an attendance payload', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'nibm-push-test-'));
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const keyPath = join(folder, 'AuthKey.p8');
  await writeFile(keyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const server = createServer(), captures = [];
  server.on('stream', (stream, headers) => {
    let body = ''; stream.on('data', chunk => { body += chunk; });
    stream.on('end', () => { captures.push({ headers, body: JSON.parse(body) }); stream.respond({ ':status': 200 }); stream.end(); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const hosts = [], sender = createAPNsSender({ keyID: 'KEY123', teamID: 'TEAM123', bundleID: 'lk.nibm.one', keyPath }, host => {
    hosts.push(host); return connect(`http://127.0.0.1:${server.address().port}`);
  });
  try {
    const store = deliveryStore([]);
    for (const environment of ['sandbox', 'production']) {
      assert.equal((await sender.send({ token, environment }, store.row, { destination: { attendance: {} }, deliveredDevices: ['secret'] })).status, 200);
    }
    assert.deepEqual(hosts, ['https://api.sandbox.push.apple.com', 'https://api.push.apple.com']);
    const { headers, body } = captures[0];
    assert.equal(headers[':path'], '/3/device/' + token);
    assert.equal(headers['apns-topic'], 'lk.nibm.one');
    assert.equal(headers['apns-push-type'], 'alert');
    assert.equal(headers['apns-id'], appID(123));
    assert.equal(body.aps.sound, 'default');
    assert.deepEqual(body.destination, { attendance: {} });
    assert.equal(body.deliveredDevices, undefined);
    const [header, claims, signature] = headers.authorization.replace('bearer ', '').split('.');
    assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
    assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iss, 'TEAM123');
    assert(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
  } finally {
    sender.close(); await new Promise(resolve => server.close(resolve));
    if (!resolve(folder).startsWith(resolve(tmpdir()) + sep) || !folder.includes('nibm-push-test-')) throw Error('Unexpected cleanup path');
    await rm(folder, { recursive: true, force: true });
  }
});
