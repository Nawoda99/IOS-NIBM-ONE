import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomInt } from 'node:crypto';
import bcrypt from 'bcryptjs';
import request from 'supertest';
import { DateTime } from 'luxon';
import { loadEnvironment, loadConfig } from '../src/config.js';
import { database, migrate } from '../src/db.js';
import { createEmployee } from '../src/records.js';
import { createApp } from '../src/app.js';
import { appID } from '../src/identity.js';

test('MySQL: request → recommendation → approval → assignment → driver GPS → completion', { skip: process.env.RUN_VEHICLE_MYSQL_TESTS !== 'true' }, async () => {
  loadEnvironment();
  const config = loadConfig();
  // This adds the application tables, then rolls back every test employee, vehicle and trip.
  if (config.database.name !== 'nibm_one_ios') throw Error('Vehicle integration verification is scoped to nibm_one_ios.');
  const db = database(config.database), marker = 'QA-' + randomUUID().slice(0, 8), rollback = new Error('ROLL_BACK_VEHICLE_QA');
  try {
    await migrate(db);
    await migrate(db); // Validate the new DDL against MySQL's SHOW CREATE TABLE output too.
    try {
      await db.transaction(async tx => {
        const password = 'VehicleQATest123!', passwordHash = await bcrypt.hash(password, 4), firstEPF = randomInt(2000000000, 2100000000);
        const people = [];
        for (let index = 0; index < 5; index++) {
          const epfNo = String(firstEPF + index);
          const id = await createEmployee(tx, { epfNo, name: marker + ' Employee ' + index, branch: 'Vehicle QA',
            role: index < 3 ? 'Administrator' : 'Employee', passwordHash, identityNo: marker + '-' + index });
          people.push({ id, epfNo });
        }
        const [owner, supervisor, manager, driver, outsider] = people;
        const app = createApp({ db: tx, config });
        const login = async person => {
          const response = await request(app).post('/api/login').send({ epfNo: person.epfNo, password }).expect(200);
          return { Authorization: 'Bearer ' + response.body.token };
        };
        const ownerAuth = await login(owner), supervisorAuth = await login(supervisor), managerAuth = await login(manager), driverAuth = await login(driver), outsiderAuth = await login(outsider);
        const date = DateTime.now().setZone('Asia/Colombo').toISODate();
        const body = { costCode: marker, supervisorID: appID(supervisor.id), placeToVisit: 'Colombo office', dutyStatus: 'Official meeting', requiredDate: date, outwardTime: '08:30', inwardTime: '17:00' };
        const directory = await request(app).get('/api/vehicles/directory').set(ownerAuth).expect(200);
        assert(directory.body.supervisors.some(person => person.id === appID(supervisor.id)));
        const created = await request(app).post('/api/vehicles/requests').set(ownerAuth).send(body).expect(201);
        const path = '/api/vehicles/requests/' + created.body.id;
        assert.equal(created.body.status, 'Pending recommendation');
        await request(app).post('/api/vehicles/requests').set(ownerAuth).send(body).expect(409);
        await request(app).post(path + '/decision').set(ownerAuth).send({ approve: true }).expect(403);
        await request(app).post(path + '/decision').set(supervisorAuth).send({ approve: true, remarks: 'Recommended' }).expect(200);
        const approved = await request(app).post(path + '/decision').set(managerAuth).send({ approve: true }).expect(200);
        assert.equal(approved.body.status, 'Approved');
        const vehicle = await request(app).post('/api/vehicles/fleet').set(managerAuth).send({ plate: marker, name: 'QA company vehicle' }).expect(201);
        const duplicateVehicle = await request(app).post('/api/vehicles/fleet').set(managerAuth).send({ plate: marker, name: 'Duplicate QA vehicle' }).expect(409);
        assert.match(duplicateVehicle.body.reason, /registration number/);
        const assigned = await request(app).post(path + '/assign').set(managerAuth).send({ vehicleID: vehicle.body.id, driverID: appID(driver.id) }).expect(200);
        assert.equal(assigned.body.status, 'Assigned');

        // A second approved request may not double-book this vehicle or this driver.
        const other = await request(app).post('/api/vehicles/requests').set(supervisorAuth).send({ ...body, supervisorID: appID(owner.id) }).expect(201);
        const otherPath = '/api/vehicles/requests/' + other.body.id;
        await request(app).post(otherPath + '/decision').set(ownerAuth).send({ approve: true }).expect(200);
        await request(app).post(otherPath + '/decision').set(managerAuth).send({ approve: true }).expect(200);
        await request(app).post(otherPath + '/assign').set(managerAuth).send({ vehicleID: vehicle.body.id, driverID: appID(driver.id) }).expect(409);
        const secondVehicle = await request(app).post('/api/vehicles/fleet').set(managerAuth).send({ plate: marker + '-2', name: 'Second QA vehicle' }).expect(201);
        await request(app).post(otherPath + '/assign').set(managerAuth).send({ vehicleID: secondVehicle.body.id, driverID: appID(driver.id) }).expect(409);

        const trips = await request(app).get('/api/vehicles/driver-trips').set(driverAuth).expect(200);
        assert(trips.body.some(trip => trip.id === created.body.id));
        const started = await request(app).post(path + '/start').set(driverAuth).expect(200);
        assert.equal(started.body.status, 'In progress');
        assert.match(started.body.sharingKey, /^[a-f0-9]{64}$/);
        assert.equal((await request(app).get(path).set(ownerAuth)).body.sharingKey, null);
        const point = { latitude: 6.9271, longitude: 79.8612, accuracy: 12, capturedAt: new Date().toISOString(), sharingKey: started.body.sharingKey };
        await request(app).post(path + '/location').set(driverAuth).send(point).expect(200);
        await request(app).get(path + '/tracking').set(outsiderAuth).expect(404);
        const tracked = await request(app).get(path + '/tracking').set(ownerAuth).expect(200);
        assert.equal(tracked.body.location.coordinate.latitude, point.latitude);
        assert.equal(tracked.body.location.isSharing, true);
        await request(app).post(path + '/location').set(ownerAuth).send(point).expect(403);
        await request(app).post(path + '/pause').set(driverAuth).send({ sharingKey: point.sharingKey }).expect(200);
        await request(app).post(path + '/location').set(driverAuth).send(point).expect(403);
        assert.equal((await request(app).get(path + '/tracking').set(ownerAuth)).body.location.isSharing, false);
        const resumed = await request(app).post(path + '/start').set(driverAuth).expect(200);
        assert.notEqual(resumed.body.sharingKey, point.sharingKey);
        await request(app).post(path + '/pause').set(driverAuth).send({ sharingKey: point.sharingKey }).expect(403);
        const complete = await request(app).post(path + '/complete').set(driverAuth).expect(200);
        assert.equal(complete.body.status, 'Completed');
        assert.equal((await request(app).get(path + '/tracking').set(ownerAuth)).body.location, null);
        await request(app).post(path + '/location').set(driverAuth).send({ ...point, sharingKey: resumed.body.sharingKey }).expect(403);
        throw rollback;
      });
    } catch (error) { if (error !== rollback) throw error; }
    assert.equal((await db.query('SELECT id FROM ios_company_vehicles WHERE plate=?', [marker])).length, 0);
    assert.equal((await db.query('SELECT id FROM ios_vehicle_requests WHERE cost_code=?', [marker])).length, 0);
  } finally { await db.close(); }
});
