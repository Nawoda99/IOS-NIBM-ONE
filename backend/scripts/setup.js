import { readFile, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
async function createEnvironment(folder, label, { optional = false, backend = false } = {}) {
  let template;
  try {
    template = await readFile(new URL('.env.example', folder), 'utf8');
  } catch (error) {
    if (!optional || error.code !== 'ENOENT') throw error;
    console.log(`${label}/.env.example is absent; skipping the separate iOS checkout.`);
    return;
  }
  if (backend) template = template.replace('GENERATE_WITH_NPM_RUN_SETUP', randomBytes(32).toString('hex'));
  try {
    await writeFile(new URL('.env', folder), template, { flag: 'wx', mode: 0o600 });
    console.log(`Created ${label}/.env.`);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    console.log(`${label}/.env exists; preserved existing settings.`);
  }
}

await createEnvironment(new URL('../', import.meta.url), 'backend', { backend: true });
await createEnvironment(new URL('../../IOS/', import.meta.url), 'IOS', { optional: true });
console.log('Set MySQL and T900 settings in backend/.env; set only public API connection settings in IOS/.env.');
