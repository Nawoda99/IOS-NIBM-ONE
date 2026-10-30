import ZKLib from 'node-zklib';
import { DateTime } from 'luxon';
import { normalisedPunch, HTTPError } from './rules.js';
import { importPunches, markFailure } from './store.js';
import { machineSelect, machineID, ATTENDANCE_SETTINGS } from './attendance.js';
import { isIP } from 'node:net';

export function sdkRecord(record, config) {
  if (!record || record.deviceUserId == null || !(record.recordTime instanceof Date) || !Number.isFinite(record.recordTime.getTime())) throw new Error('Invalid SDK attendance record.');
  // node-zklib constructs a host-local Date from the device's wall clock.
  // Preserve those components while interpreting them in the machine's configured zone.
  const date = DateTime.fromJSDate(record.recordTime).setZone(config.timezone, { keepLocalTime: true }).toUTC();
  return normalisedPunch({ epfNo: String(record.deviceUserId), timestamp: date.toISO({ suppressMilliseconds: true }),
    direction: config.directionMap[String(record.rawPunch)] ?? 'UNKNOWN', rawStatus: record.rawStatus ?? null, rawPunch: record.rawPunch ?? null,
    rawRecord: { protocol: 'node-zklib', userSn: record.userSn ?? null, rawHex: record.rawHex ?? null } });
}

function deadline(action, milliseconds) {
  let timer;
  return Promise.race([action, new Promise((_, reject) => { timer = setTimeout(() => reject(Object.assign(new Error('Device read timed out.'), { code: 'ETIMEDOUT' })), milliseconds); })])
    .finally(() => clearTimeout(timer));
}

export async function readDevice(config, SDK = ZKLib) {
  const client = new SDK(config.ip, config.port, config.timeout, config.udpPort);
  try {
    return await deadline((async () => {
      if (config.protocol === 'auto') await client.createSocket();
      else {
        const transport = config.protocol === 'udp' ? client.zklibUdp : client.zklibTcp;
        await transport.createSocket(); await transport.connect(); client.connectionType = config.protocol;
      }
      const info = await client.getInfo();
      const response = await client.getAttendances();
      if (response?.err) throw response.err;
      if (!Array.isArray(response?.data)) throw new Error('Invalid attendance response.');
      if (Number.isInteger(info?.logCounts) && info.logCounts > response.data.length) throw new Error('Incomplete attendance download; retry before relying on the sync time.');
      let rows = response.data;
      if (rows.some(row => row.userIdIsInternal)) {
        const users = await client.getUsers();
        if (users?.err || !Array.isArray(users?.data)) throw new Error('Could not resolve internal device user IDs.');
        const ids = new Map(users.data.map(user => [String(user.uid), String(user.userId)]));
        rows = rows.map(row => {
          if (!row.userIdIsInternal) return row;
          const id = ids.get(String(row.deviceUserId));
          if (id == null) throw new Error('An internal device user ID could not be mapped.');
          return { ...row, deviceUserId: id };
        });
      }
      return rows.map(row => sdkRecord(row, config));
    })(), config.readTimeout);
  } finally {
    try { await deadline(Promise.resolve().then(() => client.disconnect()), Math.min(config.timeout, 2000)); } catch { /* Best-effort protocol exit; forcibly release sockets below. */ }
    client.zklibTcp?.socket?.destroy();
    const udp = client.zklibUdp?.socket;
    if (udp) { try { udp.close(); } catch { /* Already closed. */ } }
  }
}

export function deviceError(error) {
  const code = error?.code || error?.err?.code;
  if (code === 'ETIMEDOUT' || /timeout|timed out/i.test(error?.message || error?.err?.message || '')) return 'Fingerprint machine timed out. Check the IP/port in punch_machine, terminal power and LAN access.';
  if (code === 'ECONNREFUSED') return 'Fingerprint connection was refused. Check the machine port and TCP/UDP mode.';
  if (code === 'EHOSTUNREACH' || code === 'ENETUNREACH') return 'The fingerprint machine is not reachable from the server network.';
  return 'Fingerprint read/import failed. Check machine connectivity, protocol, raw direction codes and employee mappings.';
}

export function settingsFromMachine(machine) {
  if (typeof machine.machine_ip !== 'string' || !isIP(machine.machine_ip)) throw new HTTPError(409, 'Set a valid machine_ip in punch_machine.');
  if (!Number.isInteger(machine.machine_port) || machine.machine_port < 1 || machine.machine_port > 65535) throw new HTTPError(409, 'Set a valid machine_port in punch_machine.');
  if (!Number.isInteger(machine.machine_timeout) || machine.machine_timeout < 100 || machine.machine_timeout > 60000) throw new HTTPError(409, 'Set machine_timeout between 100 and 60000 milliseconds in punch_machine.');
  if (!Number.isInteger(machine.sync_interval_minutes) || machine.sync_interval_minutes < 1) throw new HTTPError(409, 'Set a positive sync_interval_minutes in punch_machine.');
  const library = (machine.sdk_library ?? 'node-zklib').trim().toLowerCase();
  if (library && library !== 'node-zklib') throw new HTTPError(409, 'This machine requires an unsupported sdk_library. Use node-zklib for the T900.');
  return { ...ATTENDANCE_SETTINGS, ip: machine.machine_ip, port: machine.machine_port, timeout: machine.machine_timeout,
    readTimeout: Math.max(60000, machine.machine_timeout * 6), udpPort: 0, protocol: 'auto' };
}

export function createDeviceSync(db, { reader = readDevice, now = Date.now, scanMilliseconds = 1000 } = {}) {
  const active = new Map(), attempted = new Map();
  let timer = null, polling = null, started = false, stopping = false;
  const totals = () => ({ inserted: 0, duplicates: 0, unmapped: 0, received: 0 });
  const syncOne = code => {
    const id = machineID(code);
    if (active.has(id)) return active.get(id);
    if (stopping) return Promise.reject(new HTTPError(503, 'The fingerprint reader is stopping.'));
    const work = (async () => {
      let recordFailure = false;
      try {
        // Re-read before every connection: DB edits take effect without restarting Node.
        const [machine] = await db.query(machineSelect + ' WHERE m.id=?', [id]);
        if (!machine) throw new HTTPError(404, 'Fingerprint machine was not found in punch_machine.');
        if (!machine.active || !machine.sync_enabled) throw new HTTPError(409, 'Enable active and sync_enabled in punch_machine before syncing this machine.');
        recordFailure = true;
        attempted.set(id, now());
        const settings = settingsFromMachine(machine);
        const rows = await reader(settings), result = { ...totals(), received: rows.length };
        const batches = [];
        for (let offset = 0; offset < rows.length; offset += 500) batches.push(rows.slice(offset, offset + 500));
        if (!batches.length) batches.push([]);
        for (let index = 0; index < batches.length; index++) {
          const imported = await importPunches(db, id, batches[index], index === batches.length - 1, settings);
          for (const key of ['inserted', 'duplicates', 'unmapped']) result[key] += imported[key];
        }
        return result;
      } catch (error) {
        const message = error instanceof HTTPError ? error.message : deviceError(error);
        // Disabled/missing rows are a configuration choice, not a failed physical read.
        if (recordFailure) {
          try { await markFailure(db, id, message); } catch { /* Preserve the original failure. */ }
        }
        throw new HTTPError(error instanceof HTTPError ? error.status : 502, message);
      }
    })().finally(() => { active.delete(id); });
    active.set(id, work);
    return work;
  };
  const enabledMachines = () => db.query(machineSelect + ' WHERE m.active=1 AND m.sync_enabled=1 ORDER BY m.id');
  const sync = async code => {
    if (code != null) return syncOne(code);
    const machines = await enabledMachines();
    if (!machines.length) throw new HTTPError(409, 'No active, sync-enabled machines are configured in punch_machine.');
    const result = totals(), failures = [];
    for (const machine of machines) {
      if (stopping) throw new HTTPError(503, 'The fingerprint reader is stopping.');
      try {
        const imported = await syncOne(machine.id);
        for (const key of Object.keys(result)) result[key] += imported[key];
      } catch (error) { failures.push(`Machine ${machine.id}: ${error.message}`); }
    }
    if (failures.length) throw new HTTPError(502, failures.join(' '));
    return result;
  };
  const poll = () => {
    if (polling) return polling;
    polling = (async () => {
      const machines = await enabledMachines();
      const enabled = new Set(machines.map(machine => machine.id));
      for (const id of attempted.keys()) if (!enabled.has(id)) attempted.delete(id);
      for (const machine of machines) {
        if (stopping) break;
        const interval = Math.max(1, machine.sync_interval_minutes) * 60000;
        if (attempted.has(machine.id) && now() - attempted.get(machine.id) < interval) continue;
        attempted.set(machine.id, now());
        try {
          const result = await syncOne(machine.id);
          console.log(`Machine ${machine.id}: ${result.received} read, ${result.inserted} new, ${result.duplicates} duplicates, ${result.unmapped} unregistered EPF punches.`);
        } catch (error) { console.warn(`Machine ${machine.id}: ${error.message}`); }
      }
    })().finally(() => { polling = null; });
    return polling;
  };
  const tick = async () => {
    try { await poll(); } catch (error) { console.warn('Machine discovery failed:', error.code || error.name); }
    finally { if (!stopping) timer = setTimeout(tick, scanMilliseconds); }
  };
  return { sync, poll,
    start() { if (!started && !stopping) { started = true; void tick(); } },
    async stop() { stopping = true; clearTimeout(timer); await polling?.catch(() => {}); await Promise.allSettled([...active.values()]); }
  };
}

