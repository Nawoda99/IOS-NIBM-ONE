import { connect } from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DateTime } from 'luxon';
import { HTTPError, hash } from './rules.js';
import { appID } from './identity.js';

export const punchAlertMaxAge = 15 * 60 * 1000;
export async function registerPushDevice(db, user, input) {
  if (typeof input?.token !== 'string' || !/^(?:[a-f0-9]{2}){16,256}$/i.test(input.token) || !['sandbox', 'production'].includes(input.environment)) {
    throw new HTTPError(400, 'Supply an APNs device token and sandbox or production environment.');
  }
  // One installation belongs to its most recently signed-in employee only.
  await db.transaction(async tx => {
    const [session] = await tx.query('SELECT id FROM login_devices WHERE id=? AND signedOutAt IS NULL FOR UPDATE', [user.session_id]);
    if (!session) throw new HTTPError(401, 'Your session has expired. Sign in again.');
    await tx.query('DELETE FROM ios_push_devices WHERE sessionId=? AND environment=? AND token<>?', [user.session_id, input.environment, input.token.toLowerCase()]);
    await tx.query(`INSERT INTO ios_push_devices (token,environment,employeeId,sessionId,updatedAt) VALUES (?,?,?,?,?)
      ON DUPLICATE KEY UPDATE employeeId=VALUES(employeeId),sessionId=VALUES(sessionId),updatedAt=VALUES(updatedAt)`,
    [input.token.toLowerCase(), input.environment, user.id, user.session_id, new Date()]);
  });
}

export async function enqueuePunchNotification(db, employeeID, sr, punch, machine, now = new Date()) {
  const time = DateTime.fromISO(punch.timestamp).setZone('Asia/Colombo');
  // A terminal returns its whole history. Do not alert for a historical backfill.
  const age = now.getTime() - time.toMillis();
  if (!time.isValid || age > punchAlertMaxAge || age < -60000) return;
  const title = punch.direction === 'IN' ? 'Punch IN recorded' : punch.direction === 'OUT' ? 'Punch OUT recorded' : 'Attendance punch recorded';
  const body = `${time.toFormat('dd LLL yyyy, HH:mm')} · ${machine.machine_description ?? machine.machine_model}${machine.branch ? ' · ' + machine.branch : ''}`.slice(0, 500);
  await db.query(`INSERT INTO push_notification_outbox
    (employeeId,eventType,title,body,data,deduplicationKey,availableAt,createdAt,updatedAt) VALUES (?,'attendance',?,?,?,?,?,?,?)
    ON DUPLICATE KEY UPDATE deduplicationKey=VALUES(deduplicationKey)`,
  [employeeID, title, body, JSON.stringify({ destination: { attendance: {} }, punchID: appID(sr) }), `attendance:punch:${sr}`, now, now, now]);
}

export function createAPNsSender(config, connection = connect) {
  const enabled = Boolean(config?.keyID && config?.teamID && config?.bundleID && config?.keyPath);
  if (!enabled) return { enabled: false, close() {} };
  const key = createPrivateKey(readFileSync(config.keyPath));
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNS_KEY_PATH must contain an ES256 APNs signing key.');
  const sessions = new Map();
  let jwt, issuedAt = 0;
  function authorization() {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - issuedAt >= 3000) {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: config.keyID })).toString('base64url');
      const claims = Buffer.from(JSON.stringify({ iss: config.teamID, iat: now })).toString('base64url');
      const input = `${header}.${claims}`;
      jwt = `${input}.${sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
      issuedAt = now;
    }
    return jwt;
  }
  return { enabled: true,
    async send(device, notification, data) {
      let session = sessions.get(device.environment);
      if (!session || session.closed || session.destroyed) {
        session = connection(device.environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com');
        sessions.set(device.environment, session);
        session.on('error', () => { session.destroy(); });
        session.on('goaway', () => { sessions.delete(device.environment); session.close(); });
      }
      return new Promise((resolve, reject) => {
        const stream = session.request({ ':method': 'POST', ':path': `/3/device/${device.token}`,
          authorization: `bearer ${authorization()}`, 'apns-topic': config.bundleID, 'apns-push-type': 'alert',
          'apns-priority': '10', 'apns-expiration': String(Math.floor(new Date(notification.createdAt).getTime() / 1000) + 900),
          'apns-collapse-id': notification.deduplicationKey, 'apns-id': appID(notification.id) });
        let status, body = '';
        stream.setEncoding('utf8');
        const deadline = setTimeout(() => { stream.destroy(new Error('APNs request timed out.')); }, 15000);
        stream.on('close', () => { clearTimeout(deadline); reject(new Error('APNs connection closed before a response.')); });
        stream.on('response', headers => { status = Number(headers[':status']); });
        stream.on('data', chunk => { body += chunk; });
        stream.on('error', reject);
        stream.on('end', () => {
          let result = {};
          try { result = JSON.parse(body || '{}'); } catch { /* Invalid upstream response is retryable. */ }
          resolve({ status, reason: result.reason, timestamp: result.timestamp });
        });
        // Internal delivery bookkeeping is never included in the phone payload.
        stream.end(JSON.stringify({ aps: { alert: { title: notification.title, body: notification.body }, sound: 'default' },
          notificationID: appID(notification.id), destination: data.destination, punchID: data.punchID }));
      });
    },
    close() { for (const session of sessions.values()) session.destroy(); sessions.clear(); }
  };
}

const decoded = value => typeof value === 'string' ? JSON.parse(value) : value ?? {};
export function createPushWorker(db, sender, { interval = 5000, now = () => new Date() } = {}) {
  let timer, running, stopped = false;
  async function drain() {
    if (!sender.enabled || stopped) return;
    for (let count = 0; count < 50 && !stopped; count++) {
      const row = await db.transaction(async tx => {
        const [next] = await tx.query(`SELECT * FROM push_notification_outbox WHERE eventType='attendance' AND
          ((status='PENDING' AND availableAt<=?) OR (status='PROCESSING' AND updatedAt<DATE_SUB(?,INTERVAL 5 MINUTE)))
          ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED`, [now(), now()]);
        if (!next) return null;
        await tx.query("UPDATE push_notification_outbox SET status='PROCESSING',attempts=attempts+1,updatedAt=? WHERE id=?", [now(), next.id]);
        return next;
      });
      if (!row) break;
      const data = decoded(row.data), completed = new Set(data.deliveredDevices ?? []);
      let failure = null;
      if (now().getTime() - new Date(row.createdAt).getTime() > punchAlertMaxAge) failure = 'Punch alert expired.';
      else {
        const devices = await db.query(`SELECT d.* FROM ios_push_devices d JOIN employees e ON e.id=d.employeeId
          WHERE d.employeeId=? AND COALESCE(e.status,1)=1`, [row.employeeId]);
        if (!devices.length) failure = 'No registered iOS device.';
        for (const device of devices) {
          const fingerprint = hash(device.environment + ':' + device.token);
          if (completed.has(fingerprint)) continue;
          try {
            const response = await sender.send(device, row, data);
            if (response.status === 410 || (response.status === 400 && response.reason === 'BadDeviceToken')) {
              await db.query('DELETE FROM ios_push_devices WHERE token=? AND environment=? AND updatedAt<=?',
                [device.token, device.environment, response.timestamp ? new Date(response.timestamp) : device.updatedAt]);
            } else if (response.status !== 200) throw new Error(`APNs ${response.status ?? 'connection'}: ${response.reason ?? 'delivery failed'}`);
            completed.add(fingerprint);
            data.deliveredDevices = [...completed];
            await db.query('UPDATE push_notification_outbox SET data=?,updatedAt=? WHERE id=?', [JSON.stringify(data), now(), row.id]);
          } catch (error) { failure = error.message; }
        }
      }
      const exhausted = Number(row.attempts) + 1 >= 8 || now().getTime() - new Date(row.createdAt).getTime() > punchAlertMaxAge;
      const status = failure ? exhausted ? 'FAILED' : 'PENDING' : 'SENT';
      const available = new Date(now().getTime() + Math.min(300, 5 * 2 ** Number(row.attempts)) * 1000);
      await db.query('UPDATE push_notification_outbox SET status=?,availableAt=?,processedAt=?,lastError=?,updatedAt=? WHERE id=?',
        [status, available, status === 'PENDING' ? null : now(), failure?.slice(0, 500) ?? null, now(), row.id]);
    }
  }
  function poll() {
    if (!running) running = drain().finally(() => { running = null; });
    return running;
  }
  async function tick() {
    try { await poll(); } catch (error) { console.error('Push worker failed:', error.code || error.name); }
    finally { if (!stopped) timer = setTimeout(tick, interval); }
  }
  return { poll, start() { if (!timer && !running && !stopped && sender.enabled) void tick(); },
    async stop() { stopped = true; clearTimeout(timer); await running; sender.close(); } };
}
