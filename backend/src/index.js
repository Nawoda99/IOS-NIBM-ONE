import { loadEnvironment, loadConfig } from './config.js';
import { initializeDatabase } from './db.js';
import { createDeviceSync } from './fingerprint.js';
import { createApp } from './app.js';
import { createAPNsSender, createPushWorker } from './push.js';

loadEnvironment();
const config = loadConfig();
let db, worker, pushWorker, http;
try {
  db = await initializeDatabase(config);
  console.log(config.autoMigrate ? 'MySQL database and Sequelize models ready; existing records preserved.' : 'Connected to MySQL through Sequelize; automatic schema setup is disabled.');
  await db.query('UPDATE login_devices SET signedOutAt=UTC_TIMESTAMP(),updatedAt=UTC_TIMESTAMP() WHERE signedOutAt IS NULL AND createdAt<=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 8 HOUR)');
  worker = createDeviceSync(db);
  const sender = createAPNsSender(config.apns);
  pushWorker = createPushWorker(db, sender);
  console.log(sender.enabled ? 'APNs punch notifications enabled.' : 'APNs delivery disabled: configure APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID and APNS_KEY_PATH.');
  const app = createApp({ db, config, deviceSync: worker, pushEnabled: sender.enabled });
  http = await new Promise((resolve, reject) => { const server = app.listen(config.port, config.host, () => resolve(server)); server.once('error', reject); });
  console.log(`NIBM ONE Node.js API listening on ${config.host}:${config.port}; storage: MySQL; reader: node-zklib.`);
  worker.start();
  pushWorker.start();
} catch (error) {
  console.error(error.code ? `Startup failed (${error.code}). Check backend/.env, MySQL service, account privileges and port.` : error.message);
  if (db) await db.close();
  process.exitCode = 1;
}
let closing = false;
async function shutdown() {
  if (closing) return; closing = true;
  const closeHTTP = http ? new Promise(resolve => http.close(resolve)) : Promise.resolve();
  await worker?.stop(); await pushWorker?.stop(); await closeHTTP; await db?.close();
}
process.once('SIGINT', () => { void shutdown(); });
process.once('SIGTERM', () => { void shutdown(); });
