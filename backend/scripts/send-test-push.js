import { loadEnvironment, loadConfig } from '../src/config.js';
import { database } from '../src/db.js';
import { createAPNsSender } from '../src/push.js';
import { canonicalEPF } from '../src/identity.js';
import { sendTestPush } from '../src/push-diagnostics.js';

const args = process.argv.slice(2);
if (args.includes('--help')) {
  console.log('Usage: node scripts/send-test-push.js [--epf EMPLOYEE_EPF]');
  console.log('Sends one labeled test notification only when exactly one matching iPhone is registered.');
} else {
  let db, sender;
  try {
    if (args.length && (args.length !== 2 || args[0] !== '--epf')) throw new Error('Use --epf EMPLOYEE_EPF or no arguments.');
    const epf = args.length ? canonicalEPF(args[1]) : null;
    loadEnvironment();
    const config = loadConfig();
    if (config.database.name !== 'nibm_one_ios' || config.apns.bundleID !== 'com.nawoda.nibmone') {
      throw new Error('This test is scoped to the com.nawoda.nibmone assignment and nibm_one_ios database.');
    }
    sender = createAPNsSender(config.apns);
    if (!sender.enabled) throw new Error('Configure the four APNS settings in backend/.env first.');
    db = database(config.database);
    const devices = await db.query(`SELECT d.* FROM ios_push_devices d JOIN employees e ON e.id=d.employeeId
      WHERE COALESCE(e.status,1)=1${epf == null ? '' : ' AND e.epf_no=?'}`, epf == null ? [] : [Number(epf)]);
    if (!devices.length) throw new Error('No matching iPhone is registered. Sign in on the iPhone and use More > Settings > Notifications > Retry registration.');
    if (devices.length !== 1) throw new Error('More than one iPhone matches. Specify an EPF with exactly one registered iPhone; no notification was sent.');
    const id = await sendTestPush(db, sender, devices[0]);
    console.log(`Apple accepted the test notification. It is also saved in the app notification inbox (record ${id}). Open More > Notifications and pull down to refresh.`);
  } catch (error) {
    // Do not expose device tokens, key contents, or database credentials in output.
    console.error(error.code ? `Push test failed (${error.code}). Check backend/.env and server connectivity.` : error.message);
    process.exitCode = 1;
  } finally {
    sender?.close();
    await db?.close();
  }
}
