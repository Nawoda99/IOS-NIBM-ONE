import { DateTime } from 'luxon';
import { HTTPError, iso } from './rules.js';

export const attendanceTimeZone = 'Asia/Colombo';
export function attendanceMonthRange(value, now = DateTime.now()) {
  const month = value === undefined ? now.setZone(attendanceTimeZone).toFormat('yyyy-MM') : value;
  if (typeof month !== 'string' || !/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) throw new HTTPError(400, 'Use month=YYYY-MM.');
  const start = DateTime.fromISO(month + '-01', { zone: attendanceTimeZone }).startOf('month');
  if (!start.isValid || start.year < 2000 || start.year > 2100) throw new HTTPError(400, 'Choose a month between 2000 and 2100.');
  return { month, start: start.toJSDate(), end: start.plus({ months: 1 }).toJSDate() };
}
export function dailyAttendance(punches) {
  const groups = new Map();
  for (const punch of punches) {
    const date = DateTime.fromISO(punch.timestamp).setZone(attendanceTimeZone).toISODate();
    if (!groups.has(date)) groups.set(date, []);
    groups.get(date).push(punch);
  }
  return [...groups].sort(([a], [b]) => a.localeCompare(b)).map(([date, rows]) => {
    const times = [...new Set(rows.map(row => new Date(row.timestamp).getTime()))].sort((a, b) => a - b);
    const first = times[0], last = times.length > 1 ? times.at(-1) : null;
    return { date, inTime: iso(new Date(first)), outTime: last == null ? null : iso(new Date(last)), punchCount: rows.length,
      spanMinutes: last == null ? 0 : Math.floor((last - first) / 60000), status: last == null ? 'Missing punch' : 'Present' };
  });
}
