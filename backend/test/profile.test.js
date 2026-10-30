import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import request from 'supertest';
import { profile, hash } from '../src/rules.js';
import { createApp } from '../src/app.js';

test('employee profile exposes HR details without credentials, internal paths or audit fields', () => {
  const value = profile({ id: 7, epf_no: '1952', name: 'Alex Perera', branch: 'Colombo', role: 'Employee',
    first_name: ' Alex ', last_name: 'Perera', initials: 'A.P.', title: 4, gender: 0, identity_no: 'TEST-IDENTITY',
    passport_no: 'TEST-PASSPORT', department_name: 'IT', employment_type_name: 'Permanent', grade_name: 'Grade 1', status: 1,
    joined_date: new Date('2022-01-10T00:00:00Z'), appointment_date: '2022-02-01 00:00:00',
    probation_end_date: '2022-08-01', assignment_start_date: null, old_epf_no: 100, circuito_emp_id: 'ERP-10',
    official_email: 'alex@example.com', personal_email: 'alex.personal@example.com', mobile_no_1: '0710000000',
    mobile_no_2: '0720000000', tel_no_1: '0110000000', tel_no_2: '0110000001', address_1: 'Line 1\nColombo', address_2: 'Other address',
    immediate_contact_name: 'Emergency contact', immediate_contact_tel_no: '0770000000', immediate_contact_address: 'Contact address', relationship: 'Sibling',
    password: 'secret', password_hash: 'secret-hash', session_id: 'secret-session', profile_photo_path: '/private/photo.jpg', created_by_id: 42 });
  assert.equal(value.details.firstName, 'Alex');
  assert.equal(value.details.gender, 'Male'); // Zero is a valid code, not missing data.
  assert.equal(value.details.title, 'Mr');
  assert.equal(value.details.department, 'IT');
  assert.equal(value.details.employmentType, 'Permanent');
  assert.equal(value.details.grade, 'Grade 1');
  assert.equal(value.details.employmentStatus, 'Active');
  assert.equal(value.details.joinedDate, '2022-01-10');
  assert.equal(value.details.appointmentDate, '2022-02-01');
  assert.equal(value.details.probationEndDate, '2022-08-01');
  assert.equal(value.details.assignmentStartDate, null);
  assert.equal(value.details.primaryAddress, 'Line 1\nColombo');
  assert.equal(value.details.emergencyContactRelationship, 'Sibling');
  const serialized = JSON.stringify(value);
  for (const secret of ['secret', '/private/photo.jpg', 'created_by_id']) assert(!serialized.includes(secret));
});

test('missing and unknown HR values remain unset instead of inventing information', () => {
  const details = profile({ gender: 99, title: 99, status: 99, official_email: '  ', joined_date: '0000-00-00', grade_name: '', grade_code: 'G2' }).details;
  assert.equal(details.gender, null);
  assert.equal(details.title, null);
  assert.equal(details.employmentStatus, null);
  assert.equal(details.officialEmail, null);
  assert.equal(details.joinedDate, null);
  assert.equal(details.grade, 'G2');
  assert.equal(profile({ gender: 1, status: 0 }).details.gender, 'Female');
  assert.equal(profile({ gender: 1, status: 0 }).details.employmentStatus, 'Inactive');
});

test('login and snapshot return only the authenticated employee personal details', async () => {
  const password = 'TestingPass123!', passwordHash = await bcrypt.hash(password, 4), sessions = new Map();
  const employees = [
    { id: 7, epf_no: '1952', name: 'First Employee', role: 'Employee', identity_no: 'FIRST-IDENTITY', official_email: 'first@example.com' },
    { id: 8, epf_no: '1953', name: 'Second Employee', role: 'Employee', identity_no: 'SECOND-IDENTITY', official_email: 'second@example.com' }
  ].map(row => ({ ...row, branch: 'Colombo', password_hash: passwordHash }));
  const db = { sequelize: { config: { database: 'profile_test_' + randomUUID().replaceAll('-', '') } },
    query: async (sql, values = []) => {
      if (sql.includes('JOIN login_devices')) {
        const session = sessions.get(values[0]);
        return session ? [{ ...employees.find(row => row.id === session.employeeID), session_id: session.id }] : [];
      }
      if (sql.includes('WHERE e.epf_no=')) return employees.filter(row => Number(row.epf_no) === values[0]);
      if (sql.startsWith('INSERT INTO login_devices')) { sessions.set(values[2], { id: values[0], employeeID: values[1] }); return {}; }
      if (sql.trim().startsWith('SELECT')) return [];
      throw Error('Unexpected query');
    }, transaction: async action => action(db) };
  const app = createApp({ db, config: {} });
  await request(app).get('/api/snapshot').expect(401);
  for (const employee of employees) {
    const login = await request(app).post('/api/login').send({ epfNo: employee.epf_no, password }).expect(200);
    assert.equal(login.body.profile.details.identityNumber, employee.identity_no);
    const snapshot = await request(app).get('/api/snapshot?employeeId=8&epfNo=1953').set('Authorization', 'Bearer ' + login.body.token).expect(200);
    assert.equal(snapshot.body.profile.details.officialEmail, employee.official_email);
    assert.equal(snapshot.body.profile.details.identityNumber, employee.identity_no);
    assert(!JSON.stringify(snapshot.body).includes(employees.find(row => row.id !== employee.id).identity_no));
    assert.equal(snapshot.body.profile.password_hash, undefined);
    assert(sessions.has(hash(login.body.token)));
  }
});
