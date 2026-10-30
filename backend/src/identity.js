import { HTTPError, epfNumber, uuid } from './rules.js';

// Keep the iOS UUID wire format without adding UUID columns to the backup tables.
export function appID(id) {
  const value = BigInt(id);
  if (value < 1n || value > 0xffffffffffffn) throw new Error('Record ID is outside the supported app range.');
  return '00000000-0000-4000-8000-' + value.toString(16).padStart(12, '0');
}
export function databaseID(value) {
  uuid(value);
  if (!/^00000000-0000-4000-8000-[0-9a-f]{12}$/i.test(value)) throw new HTTPError(400, 'Invalid database record ID.');
  const id = Number(BigInt('0x' + value.slice(-12)));
  if (id < 1) throw new HTTPError(400, 'Invalid database record ID.');
  return id;
}
export function canonicalEPF(value) {
  const epf = BigInt(epfNumber(value));
  if (epf > 2147483647n) throw new HTTPError(400, 'EPF No. exceeds the backup INT column range.');
  return String(epf);
}
