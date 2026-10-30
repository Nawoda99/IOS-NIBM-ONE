import { Sequelize, QueryTypes } from 'sequelize';
import bcrypt from 'bcryptjs';
import { defineModels } from './models.js';
import { createEmployee, seedLeaveTypes } from './records.js';
import { backupTables } from './backup-schema.js';
import { pushTables } from './push-schema.js';
import { vehicleTables } from './vehicle-schema.js';

function databaseError(error) {
  // Preserve the driver's error code for the existing HTTP/startup error handlers.
  if (error.original?.code) error.code = error.original.code;
  return error;
}

export class Database {
  constructor(sequelize, transaction = null) {
    this.sequelize = sequelize;
    this.activeTransaction = transaction;
    this.models = sequelize.models;
  }
  async query(sql, values = []) {
    try {
      // Sequelize's default Date escaping omits milliseconds. Preserve DATETIME(3) precision.
      const replacements = values.map(value => value instanceof Date ? value.toISOString().replace('T', ' ').replace('Z', '') : value);
      const [rows, metadata] = await this.sequelize.query(sql, {
        replacements, type: QueryTypes.RAW, transaction: this.activeTransaction
      });
      // MySQL's Sequelize dialect returns [insertId, affectedRows] for raw INSERTs.
      if (typeof rows === 'number' && typeof metadata === 'number') return { insertId: rows, affectedRows: metadata };
      return rows;
    } catch (error) { throw databaseError(error); }
  }
  async transaction(action) {
    try {
      return await this.sequelize.transaction({ transaction: this.activeTransaction },
        transaction => action(new Database(this.sequelize, transaction)));
    } catch (error) { throw databaseError(error); }
  }
  async close() { await this.sequelize.close(); }
}

function connection(config, withDatabase = true) {
  if (!/^[a-zA-Z0-9_]{1,64}$/.test(config.name)) throw new Error('Use only letters, digits and underscores for DATABASE_NAME.');
  return new Sequelize(withDatabase ? config.name : '', config.user, config.password, {
    dialect: 'mysql', host: config.host, port: config.port, timezone: '+00:00', logging: false,
    dialectOptions: { charset: 'utf8mb4', connectTimeout: 5000, decimalNumbers: true,
      ...(config.tls ? { ssl: { rejectUnauthorized: true } } : {}) },
    pool: { max: 8, min: 0, acquire: 10000, idle: 10000 }, retry: { max: 0 }
  });
}
export function database(config) {
  const sequelize = connection(config);
  defineModels(sequelize);
  return new Database(sequelize);
}
export async function createDatabase(config) {
  const sequelize = connection(config, false);
  try {
    await sequelize.getQueryInterface().createDatabase(config.name, { charset: 'utf8mb4', collate: 'utf8mb4_unicode_ci' });
  } catch (error) { throw databaseError(error); }
  finally { await sequelize.close(); }
}

// Shared by normal startup and the optional explicit migrate command.
export async function initializeDatabase(config) {
  if (!config.database.password || config.database.password === 'CHANGE_ME_LOCALLY') throw new Error('Enter MySQL settings locally in backend/.env before starting.');
  let db;
  try {
    if (config.autoMigrate) await createDatabase(config.database);
    db = database(config.database);
    await db.sequelize.authenticate();
    if (config.autoMigrate) await migrate(db);
    if (config.seedDemo) await seed(db);
    return db;
  } catch (error) {
    if (db) await db.close();
    throw databaseError(error);
  }
}
export async function migrate(db) {
  const tables = [...backupTables, ...pushTables, ...vehicleTables];
  const names = new Set(tables.map(table => table.name));
  const present = new Set((await db.query('SHOW TABLES')).map(row => Object.values(row)[0]));
  const extra = [...present].filter(name => !names.has(name));
  if (extra.length) throw new Error('The selected database contains tables outside the exact backup subset. Use a fresh DATABASE_NAME; existing data was preserved.');
  for (const table of tables) {
    if (present.has(table.name)) {
      const [row] = await db.query('SHOW CREATE TABLE ' + db.sequelize.getQueryInterface().queryGenerator.quoteIdentifier(table.name));
      if (normalizeDDL(row['Create Table']) !== normalizeDDL(table.ddl)) throw new Error('Schema mismatch in ' + table.name + '. Use a fresh exact-schema database; existing data was preserved.');
    }
  }
  for (const table of tables) if (!present.has(table.name)) await db.query(table.ddl);
  await seedLeaveTypes(db);
}
export function normalizeDDL(value) {
  return value.replace(/ AUTO_INCREMENT=\d+/g, '').replace(/;$/, '').replace(/\s+/g, ' ').trim();
}
export async function seed(db) {
  for (const [epfNo, name, role, password] of [
    ['900001', 'Alex Perera', 'Employee', 'Demo@123'],
    ['900002', 'Demo Manager', 'Approver', 'Manager@123'],
    ['900003', 'Demo Support', 'Support', 'Support@123']
  ]) {
    const exists = await db.query('SELECT id FROM employees WHERE epf_no=?', [epfNo]);
    if (!exists.length) await createEmployee(db, { epfNo, name, branch: 'Colombo', role, passwordHash: await bcrypt.hash(password, 12), identityNo: 'DEMO-' + epfNo });
  }
}
