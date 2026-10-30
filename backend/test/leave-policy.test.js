import test from 'node:test';
import assert from 'node:assert/strict';
import {DateTime} from 'luxon';
import {leaveDays} from '../src/rules.js';
import {createAccount} from '../src/administration.js';
import {appID} from '../src/identity.js';
const now=DateTime.fromISO('2026-10-30T12:00:00+05:30');
const input={type:'Annual',start:'2026-07-10T03:00:00Z',end:'2026-07-11T03:00:00Z',halfDay:false,reason:'Retrospective leave'};
test('past full-day and half-day leave are permitted',()=>{
  assert.equal(leaveDays(input,[],now),2);
  assert.equal(leaveDays({...input,end:input.start,halfDay:true},[],now),0.5);
});
test('retrospective leave still enforces dates, overlaps, balance and cross-year rules',()=>{
  assert.throws(()=>leaveDays({...input,end:'2026-07-09T03:00:00Z'},[],now),error=>error.status===400);
  assert.throws(()=>leaveDays({...input,halfDay:true},[],now),error=>error.status===400);
  assert.throws(()=>leaveDays({...input,end:'2027-01-01T03:00:00Z'},[],now),error=>error.status===400);
  assert.throws(()=>leaveDays(input,[{type:'Annual',startDate:input.start,endDate:input.end,status:'Pending',days:2}],now),error=>error.status===409);
  assert.throws(()=>leaveDays(input,[],now,{Annual:1}),error=>error.status===409);
});
test('login creation rejects new employee details and unknown employees without inserts',async()=>{
  let inserted=false;
  const tx={query:async sql=>{if(sql.startsWith('INSERT'))inserted=true;return[];}};
  const db={transaction:async operation=>operation(tx)};
  await assert.rejects(createAccount(db,{employeeID:appID(999999),password:'TestingPass123!',role:'Employee',name:'Not permitted'},1),error=>error.status===400);
  await assert.rejects(createAccount(db,{employeeID:appID(999999),password:'TestingPass123!',role:'Employee'},1),error=>error.status===404);
  assert.equal(inserted,false);
});
