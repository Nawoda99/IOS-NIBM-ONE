import { loadEnvironment, loadConfig } from '../src/config.js';
import { initializeDatabase } from '../src/db.js';
loadEnvironment();
const config = loadConfig();
let db;
try {
  db = await initializeDatabase({ ...config, autoMigrate: true });
  console.log('MySQL database/Sequelize models ready. Existing records and passwords were preserved.');
} catch (error) {
  console.error(`MySQL setup failed (${error.code || 'configuration'}). Check local backend/.env settings and database privileges.`);
  process.exitCode = 1;
} finally { if (db) await db.close(); }
