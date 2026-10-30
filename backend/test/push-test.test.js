import test from 'node:test';
import assert from 'node:assert/strict';
import { sendTestPush } from '../src/push-diagnostics.js';
import { records } from '../src/records.js';
import { appID } from '../src/identity.js';

test('test push is persisted for its recipient before Apple receives it and uses the inbox record ID', async () => {
  const events = [], rows = [];
  const db = { query: async (sql, values) => {
    if (sql.startsWith('INSERT')) {
      events.push('inbox');
      rows.push({ id: 42, employeeId: values[0], title: values[1], data: values[3], createdAt: values[5], readAt: null });
      return { insertId: 42 };
    }
    if (sql.startsWith('UPDATE')) { assert.equal(values[2], 42); events.push('sent'); return {}; }
    if (sql.startsWith('SELECT')) return rows.filter(row => row.employeeId === values[0]);
    throw Error('Unexpected query');
  } };
  const device = { employeeId: 7, environment: 'sandbox', token: 'ab'.repeat(32) };
  const sender = { send: async (target, notification, data) => {
    assert.deepEqual(events, ['inbox']);
    assert.equal(target, device);
    assert.equal(notification.id, 42);
    assert.equal(data.isTest, true);
    assert.deepEqual(data.destination, { attendance: {} });
    events.push('apns'); return { status: 200 };
  } };
  assert.equal(await sendTestPush(db, sender, device), 42);
  assert.deepEqual(events, ['inbox', 'apns', 'sent']);
  const inbox = await records(db, 7, 'notice');
  assert.equal(inbox.length, 1);
  assert.equal(inbox[0].id, appID(42));
  assert.equal(inbox[0].title, 'NIBM ONE test notification');
  assert.equal(inbox[0].isRead, false);
  assert.equal((await records(db, 8, 'notice')).length, 0);
});

test('failed APNs test retains its inbox entry and records the failed delivery', async () => {
  const calls = [];
  const db = { query: async (sql, values) => { calls.push({ sql, values }); return { insertId: 42 }; } };
  await assert.rejects(sendTestPush(db, { send: async () => ({ status: 403, reason: 'InvalidProviderToken' }) }, { employeeId: 7 }), /InvalidProviderToken/);
  assert.match(calls[0].sql, /INSERT INTO push_notification_outbox/);
  assert.match(calls[1].sql, /status='FAILED'/);
  assert.equal(calls[1].values[3], 42);
});

test('inbox persistence failure prevents a notification that cannot appear in app history', async () => {
  let sent = false;
  const db = { query: async () => { throw Error('Storage unavailable'); } };
  await assert.rejects(sendTestPush(db, { send: async () => { sent = true; } }, { employeeId: 7 }), /Storage unavailable/);
  assert.equal(sent, false);
});
