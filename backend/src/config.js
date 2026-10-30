import dotenv from 'dotenv';
import { fileURLToPath } from 'node:url';

export function loadEnvironment() {
  dotenv.config({ path: fileURLToPath(new URL('../.env', import.meta.url)), quiet: true });
}
function integer(value, fallback, minimum, maximum, name) {
  const result = Number(value ?? fallback);
  if (!Number.isInteger(result) || result < minimum || result > maximum) throw new Error(`Invalid ${name}.`);
  return result;
}
export function loadConfig(env = process.env) {
  return {
    host: env.HOST || '0.0.0.0', port: integer(env.PORT, 8080, 1, 65535, 'PORT'),
    database: { host: env.DATABASE_HOST || '127.0.0.1', port: integer(env.DATABASE_PORT, 3306, 1, 65535, 'DATABASE_PORT'),
      user: env.DATABASE_USERNAME || 'nibmone', password: env.DATABASE_PASSWORD || '', name: env.DATABASE_NAME || 'nibm_one_ios', tls: env.DATABASE_TLS === 'true' },
    autoMigrate: env.AUTO_MIGRATE !== 'false', seedDemo: env.SEED_DEMO_USERS === 'true', ingestKey: env.INGEST_API_KEY || ''
  };
}
