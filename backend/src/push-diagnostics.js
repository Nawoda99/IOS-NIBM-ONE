import { randomUUID } from 'node:crypto';

// Store the inbox entry before delivery so foreground refreshes can see it immediately.
export async function sendTestPush(db, sender, device) {
  const now = new Date(), data = { destination: { attendance: {} }, isTest: true };
  const notification = {
    createdAt: now, deduplicationKey: 'assignment-test-' + randomUUID(),
    title: 'NIBM ONE test notification', body: 'This is a test notification from your NIBM ONE assignment backend.'
  };
  const { insertId } = await db.query(`INSERT INTO push_notification_outbox
    (employeeId,eventType,title,body,data,deduplicationKey,status,attempts,availableAt,createdAt,updatedAt)
    VALUES (?,'push-test',?,?,?,?,'PROCESSING',1,?,?,?)`,
  [device.employeeId, notification.title, notification.body, JSON.stringify(data), notification.deduplicationKey, now, now, now]);
  notification.id = insertId;
  try {
    const response = await sender.send(device, notification, data);
    if (response.status !== 200) throw new Error(`APNs rejected the test: ${response.status ?? 'connection error'} ${response.reason ?? ''}`.trim());
  } catch (error) {
    await db.query("UPDATE push_notification_outbox SET status='FAILED',lastError=?,processedAt=?,updatedAt=? WHERE id=?",
      [String(error.message || 'Test delivery failed.').slice(0, 500), new Date(), new Date(), insertId]);
    throw error;
  }
  await db.query("UPDATE push_notification_outbox SET status='SENT',lastError=NULL,processedAt=?,updatedAt=? WHERE id=?", [new Date(), new Date(), insertId]);
  return insertId;
}
