import bcrypt from 'bcryptjs';
import {HTTPError,uuid} from './rules.js';
import {appID,databaseID,canonicalEPF} from './identity.js';
import {ensureRole,employeeSelect} from './records.js';
import {appRoles} from './access.js';

export async function employeeAccounts(db,search='',availableOnly=false){
  const query=typeof search==='string'?search.trim().slice(0,100):'';
  const rows=await db.query(employeeSelect.replace('JOIN user_credentials c','LEFT JOIN user_credentials c')+' WHERE (CAST(e.epf_no AS CHAR) LIKE ? OR e.full_name LIKE ?)'+(availableOnly?' AND c.id IS NULL AND COALESCE(e.status,1)=1 AND e.epf_no IS NOT NULL':'')+' ORDER BY e.full_name LIMIT '+(availableOnly?1000:200),['%'+query+'%','%'+query+'%']);
  return rows.map(row=>({id:appID(row.id),epfNo:String(row.epf_no??''),name:row.name,branchID:row.branch_id,branch:row.branch??'',role:row.role,hasLogin:!!row.password_hash,isActive:row.status==null||row.status===1}));
}
async function branchID(db,value){
  if(value==null)return null;
  if(!Number.isInteger(value)||value<1||!(await db.query('SELECT id FROM branch WHERE id=? AND status=1',[value])).length)throw new HTTPError(400,'Select an active branch.');
  return value;
}
export async function setEmployeeRole(tx,id,role,actorID){
  if(!appRoles.includes(role))throw new HTTPError(400,'Invalid application role.');
  const administrator=await ensureRole(tx,'Administrator');
  // A shared database row serialises changes that could remove the last administrator.
  await tx.query('SELECT id FROM system_roles WHERE id=? FOR UPDATE',[administrator]);
  const [existing]=await tx.query(employeeSelect+' WHERE e.id=?',[id]);
  if(existing?.role==='Administrator'&&role!=='Administrator'){
    const admins=await tx.query("SELECT DISTINCT e.id FROM employees e JOIN employee_system_roles er ON er.employee_id=e.id JOIN system_roles r ON r.id=er.role_id JOIN user_credentials c ON c.employeeId=e.id WHERE r.code IN ('ADMINISTRATOR','ADMIN') AND COALESCE(r.status,1)=1 AND COALESCE(e.status,1)=1 AND (c.expiry IS NULL OR c.expiry>UTC_TIMESTAMP()) FOR UPDATE");
    if(admins.length<=1)throw new HTTPError(409,'At least one active Administrator must remain.');
  }
  await tx.query("DELETE er FROM employee_system_roles er JOIN system_roles r ON r.id=er.role_id WHERE er.employee_id=? AND r.code IN ('EMPLOYEE','APPROVER','SUPPORT','ADMINISTRATOR','ADMIN')",[id]);
  const roleID=await ensureRole(tx,role);
  await tx.query('INSERT INTO employee_system_roles (employee_id,role_id,created_by_id,modified_by_id) VALUES (?,?,?,?)',[id,roleID,actorID,actorID]);
}
export async function createAccount(db,input,actorID){
  if(Object.keys(input).some(key=>!['employeeID','password','role'].includes(key)))throw new HTTPError(400,'Select an existing employee. Login creation cannot add or change employee details.');
  const id=databaseID(uuid(input.employeeID)),role=input.role??'Employee';
  if(!appRoles.includes(role))throw new HTTPError(400,'Invalid role.');
  if(typeof input.password!=='string'||input.password.length<8||Buffer.byteLength(input.password)>72)throw new HTTPError(400,'Use a password of at least 8 characters and at most 72 UTF-8 bytes.');
  const password=await bcrypt.hash(input.password,12);
  return db.transaction(async tx=>{
    const now=new Date();
    const [employee]=await tx.query('SELECT id,status,epf_no FROM employees WHERE id=? FOR UPDATE',[id]);
    if(!employee)throw new HTTPError(404,'Select an existing employee. New employee creation is not available here.');
    const epf=canonicalEPF(String(employee.epf_no??''));
    if(employee.status!=null&&employee.status!==1)throw new HTTPError(409,'This employee is inactive.');
    if((await tx.query('SELECT id FROM user_credentials WHERE employeeId=?',[employee.id])).length)throw new HTTPError(409,'This employee already has login access.');
    await tx.query('INSERT INTO user_credentials (username,password,lastUpdated,employeeId,createdAt,updatedAt) VALUES (?,?,?,?,?,?)',[epf,password,now,employee.id,now,now]);
    await setEmployeeRole(tx,employee.id,role,actorID);
    return{id:appID(employee.id),epfNo:epf};
  });
}
export async function updateAccount(db,id,input,actorID){
  const employeeID=databaseID(uuid(id));
  await db.transaction(async tx=>{
    const [employee]=await tx.query('SELECT id FROM employees WHERE id=? FOR UPDATE',[employeeID]);
    if(!employee)throw new HTTPError(404,'Employee not found.');
    await setEmployeeRole(tx,employeeID,input.role,actorID);
    if(Object.hasOwn(input,'branchID')){
      const branch=await branchID(tx,input.branchID);
      await tx.query('UPDATE employees SET branch_id=?,modified_by_id=?,updatedAt=? WHERE id=?',[branch,actorID,new Date(),employeeID]);
    }
  });
}
