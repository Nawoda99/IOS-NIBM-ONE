import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {rm} from 'node:fs/promises';
import {resolve,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import request from 'supertest';
import {createApp} from '../src/app.js';
import {hash} from '../src/rules.js';
import {defaults,permissionsFor,savePermissions,appRoles} from '../src/access.js';

const namespace='access_test_'+randomUUID().replaceAll('-','');
let mutations=0;
const db={sequelize:{config:{database:namespace}},query:async(sql,values)=>{
  if(sql.includes('JOIN login_devices')){
    const role=appRoles.find(role=>hash('token-'+role)===values[0]);
    return role?[{id:1,epf_no:1952,name:'Test employee',role,branch:'Test branch',session_id:'test-session'}]:[];
  }
  mutations++;throw Error('Unexpected database mutation/query');
},transaction:async()=>{mutations++;throw Error('Unexpected database transaction');}};
const app=createApp({db,config:{ingestKey:''}});
const as=role=>({Authorization:'Bearer token-'+role});

test('account and role administration denies unauthenticated, employee, approver and support requests',async()=>{
  for(const role of [null,'Employee','Approver','Support']){
    const status=role?403:401,headers=role?as(role):{};
    for(const [method,path] of [['get','/api/admin/employees'],['post','/api/admin/employees'],['patch','/api/admin/employees/00000000-0000-0000-0000-000000000001'],['get','/api/admin/permissions'],['put','/api/admin/permissions/Employee'],['put','/api/admin/branches/33/location']]){
      const response=await request(app)[method](path).set(headers).send({role:'Administrator',permissions:['users.manage']});
      assert.equal(response.status,status,role+' '+path);
    }
  }
  assert.equal(mutations,0);
});
test('administrator receives the permission catalogue but cannot change administrator or grant administration to another role',async()=>{
  const catalog=await request(app).get('/api/admin/permissions').set(as('Administrator'));
  assert.equal(catalog.status,200);
  assert(catalog.body.roles.find(r=>r.role==='Administrator').permissions.includes('users.manage'));
  assert.equal((await request(app).put('/api/admin/permissions/Administrator').set(as('Administrator')).send({permissions:[]})).status,400);
  assert.equal((await request(app).put('/api/admin/permissions/Employee').set(as('Administrator')).send({permissions:['users.manage']})).status,400);
});
test('role changes persist, apply to existing sessions and require view/action dependencies',async()=>{
  await savePermissions(db,'Employee',defaults.Employee.filter(p=>!['attendance.view','leave.apply'].includes(p)));
  assert.equal((await request(app).get('/api/attendance?month=2026-10').set(as('Employee'))).status,403);
  assert.equal((await request(app).post('/api/leave').set(as('Employee')).send({})).status,403);
  assert.equal((await request(app).post('/api/tickets/00000000-0000-0000-0000-000000000001/advance').set(as('Employee')).send({})).status,403);
  await assert.rejects(savePermissions(db,'Support',['tickets.manage']),error=>error.status===400);
  assert((await permissionsFor(db,'Administrator')).includes('branches.manage'));
  assert.equal(mutations,0);
});
test('account validation rejects weak passwords and invalid roles before any database changes',async()=>{
  assert.equal((await request(app).post('/api/admin/employees').set(as('Administrator')).send({epfNo:'999999',password:'short',role:'Employee'})).status,400);
  assert.equal((await request(app).post('/api/admin/employees').set(as('Administrator')).send({epfNo:'999999',password:'TestPass123',role:'Superuser'})).status,400);
  assert.equal(mutations,0);
});
test.after(async()=>{
  const root=fileURLToPath(new URL('../storage',import.meta.url)),target=resolve(root,namespace);
  if(!target.startsWith(root+sep)||!/^access_test_[a-f0-9]{32}$/.test(namespace))throw Error('Unexpected test cleanup path');
  await rm(target,{recursive:true,force:true});
});
