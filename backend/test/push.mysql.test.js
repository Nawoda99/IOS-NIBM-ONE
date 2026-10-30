import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { rm } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import bcrypt from 'bcryptjs';
import request from 'supertest';
import { loadEnvironment, loadConfig } from '../src/config.js';
import { createDatabase, database, migrate } from '../src/db.js';
import { createEmployee, records } from '../src/records.js';
import { registerMachine, importPunches } from '../src/attendance.js';
import { createPushWorker } from '../src/push.js';
import { createApp } from '../src/app.js';

test('MySQL: additive migration, punch transaction, delivery, account transfer and logout', { skip: process.env.RUN_PUSH_MYSQL_TESTS !== 'true' }, async () => {
  loadEnvironment();
  const base = loadConfig(), name = 'push_test_' + randomUUID().replaceAll('-', '');
  const config = { ...base, database: { ...base.database, name }, autoMigrate: true, seedDemo: false };
  let db;
  try {
    await createDatabase(config.database);
    db = database(config.database);
    await migrate(db);
    await migrate(db); // Must also accept MySQL's canonical SHOW CREATE TABLE output.
    const password = 'TestingPass123!', passwordHash = await bcrypt.hash(password, 4);
    const first = await createEmployee(db, { epfNo: '1952', name: 'First Employee', branch: 'Colombo', role: 'Employee', passwordHash, identityNo: 'TEST-A' });
    const second = await createEmployee(db, { epfNo: '1953', name: 'Second Employee', branch: 'Colombo', role: 'Employee', passwordHash, identityNo: 'TEST-B' });
    const app = createApp({ db, config, pushEnabled: true });
    const login = async epfNo => {
      const response = await request(app).post('/api/login').send({ epfNo, password }).expect(200);
      return { Authorization: 'Bearer ' + response.body.token };
    };
    const firstAuth = await login('1952'), secondAuth = await login('1953');
    const token = 'ab'.repeat(32), device = { token, environment: 'sandbox' };
    await request(app).put('/api/push/device').set(firstAuth).send(device).expect(204);
    const machine = await registerMachine(db, { name: 'Gate 1', branch: 'Colombo', ip: '127.0.0.1' });
    const punch = { epfNo: '1952', timestamp: new Date().toISOString(), direction: 'IN' };
    assert.equal((await importPunches(db, String(machine.id), [punch])).inserted, 1);
    assert.equal((await importPunches(db, String(machine.id), [punch])).duplicates, 1);
    assert.equal((await records(db, first, 'notice')).length, 1);
    assert.deepEqual((await records(db, first, 'notice'))[0].destination, { attendance: {} });
    assert.equal((await records(db, second, 'notice')).length, 0);
    const deliveries = [], sender = { enabled: true, close() {}, send: async (device, row) => {
      deliveries.push({ device, row }); return { status: 200 };
    } };
    const workers = [createPushWorker(db, sender), createPushWorker(db, sender)];
    await Promise.all(workers.map(worker => worker.poll()));
    assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].device.employeeId, first);
    assert.equal((await db.query('SELECT status FROM push_notification_outbox'))[0].status, 'SENT');
    await Promise.all(workers.map(worker => worker.stop()));
    await request(app).put('/api/push/device').set(secondAuth).send({ ...device, employeeId: first }).expect(204);
    assert.equal((await db.query('SELECT employeeId FROM ios_push_devices'))[0].employeeId, second);
    await request(app).post('/api/logout').set(firstAuth).expect(204);
    assert.equal((await db.query('SELECT employeeId FROM ios_push_devices')).length, 1);
    await request(app).post('/api/logout').set(secondAuth).expect(204);
    assert.equal((await db.query('SELECT employeeId FROM ios_push_devices')).length, 0);
  } finally {
    if (db) {
      if (!/^push_test_[a-f0-9]{32}$/.test(name) || db.sequelize.config.database !== name) throw Error('Unexpected test database');
      await db.query('DROP DATABASE `' + name + '`');
      await db.close();
    }
    const root = fileURLToPath(new URL('../storage', import.meta.url)), target = resolve(root, name);
    if (!target.startsWith(resolve(root) + sep) || !/^push_test_[a-f0-9]{32}$/.test(name)) throw Error('Unexpected cleanup path');
    await rm(target, { recursive: true, force: true });
  }
});
