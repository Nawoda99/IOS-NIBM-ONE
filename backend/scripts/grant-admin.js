import {parseArgs} from 'node:util';
import {loadEnvironment,loadConfig} from '../src/config.js';
import {database} from '../src/db.js';
import {canonicalEPF} from '../src/identity.js';
import {employeeSelect} from '../src/records.js';
import {setEmployeeRole} from '../src/administration.js';

// Local database-owner bootstrap only. There is intentionally no public grant endpoint.
loadEnvironment();
let db;
try{
  const {values}=parseArgs({options:{epf:{type:'string'}}});
  const epf=canonicalEPF(values.epf);db=database(loadConfig().database);
  const [employee]=await db.query(employeeSelect+' WHERE e.epf_no=?',[Number(epf)]);
  if(!employee||employee.status!=null&&employee.status!==1)throw Error('Use an active employee with existing login access.');
  await db.transaction(async tx=>{await tx.query('SELECT id FROM employees WHERE id=? FOR UPDATE',[employee.id]);await setEmployeeRole(tx,employee.id,'Administrator',employee.id);});
  console.log('Administrator assigned to EPF '+epf+'. Existing password preserved.');
}catch(error){console.error(error.code??error.message);process.exitCode=1;}finally{await db?.close();}
