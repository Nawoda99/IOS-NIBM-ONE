import {readFile, mkdir, writeFile, rename} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {HTTPError} from './rules.js';

export const appRoles = ['Employee', 'Approver', 'Support', 'Administrator'];
export const permissionCatalog = [
  ['attendance.view','Attendance','View own attendance and punches'],
  ['leave.view','Leave history','View own leave and balances'],
  ['leave.apply','Apply for leave','Submit own leave requests'],
  ['leave.approve','Approve leave','Decide other employees’ requests'],
  ['tickets.view','Tickets','View own service requests'],
  ['tickets.create','Create tickets','Submit tickets and scan assets'],
  ['tickets.manage','Support workflow','View and progress authorised service requests'],
  ['map.view','Branch and ticket map','View campuses, ticket pins and current location'],
  ['machines.manage','Fingerprint machines','Inspect and synchronise registered machines'],
  ['vehicles.request','Vehicle requests','Request a vehicle and view own trips'],
  ['vehicles.recommend','Vehicle recommendations','Recommend requests addressed to you'],
  ['vehicles.manage','Company vehicles','Approve requests, manage vehicles, assign drivers and track active trips']
].map(([id,title,description])=>({id,title,description}));
const employee=['attendance.view','leave.view','leave.apply','tickets.view','tickets.create','map.view','vehicles.request'];
export const defaults={Employee:employee,Approver:[...employee,'leave.approve','machines.manage','vehicles.recommend'],Support:[...employee,'tickets.manage','machines.manage']};
const adminPermissions=[...permissionCatalog.map(p=>p.id),'users.manage','roles.manage','branches.manage'];
const queues=new Map();
function file(db,name){
  const namespace=db.sequelize.config.database;
  if(!/^[a-zA-Z0-9_]{1,64}$/.test(namespace))throw Error('Invalid storage namespace');
  return join(resolve(fileURLToPath(new URL('../storage/',import.meta.url)),namespace,'configuration'),name+'.json');
}
export async function readConfiguration(db,name,fallback){
  try{return JSON.parse(await readFile(file(db,name),'utf8'));}catch(error){if(error.code==='ENOENT')return fallback;throw error;}
}
export async function updateConfiguration(db,name,mutate){
  const target=file(db,name),previous=queues.get(target)??Promise.resolve();
  const next=previous.catch(()=>{}).then(async()=>{
    const current=await readConfiguration(db,name,{}),value=await mutate(current);
    await mkdir(resolve(target,'..'),{recursive:true});
    const temporary=target+'.'+randomUUID()+'.tmp';
    await writeFile(temporary,JSON.stringify(value,null,2),{mode:0o600});
    await rename(temporary,target);return value;
  });
  queues.set(target,next);
  try{return await next;}finally{if(queues.get(target)===next)queues.delete(target);}
}
export async function permissionsFor(db,role){
  if(role==='Administrator')return [...adminPermissions];
  const configured=await readConfiguration(db,'role-permissions',{});
  const permissions=configured[role]??defaults[role]??[];
  const valid=new Set(permissionCatalog.map(p=>p.id));
  return Array.isArray(permissions)?permissions.filter(p=>valid.has(p)):[];
}
export const hasPermission=(user,key)=>user.permissions?.includes(key)===true;
export function requirePermission(key){return(req,_res,next)=>{if(!hasPermission(req.user,key))throw new HTTPError(403,'You do not have permission for this action.');next();};}
export function requireAdministrator(req,_res,next){if(req.user.role!=='Administrator')throw new HTTPError(403,'Administrator access is required.');next();}
export async function savePermissions(db,role,permissions){
  if(!appRoles.includes(role)||role==='Administrator')throw new HTTPError(400,'Administrator permissions cannot be changed.');
  const valid=new Set(permissionCatalog.map(p=>p.id));
  if(!Array.isArray(permissions)||permissions.some(p=>!valid.has(p)))throw new HTTPError(400,'Invalid permission selection.');
  const selected=[...new Set(permissions)];
  for(const [action,view] of [['leave.apply','leave.view'],['leave.approve','leave.view'],['tickets.create','tickets.view'],['tickets.manage','tickets.view']]){
    if(selected.includes(action)&&!selected.includes(view))throw new HTTPError(400,'Enable the related view permission before enabling an action.');
  }
  await updateConfiguration(db,'role-permissions',current=>({...current,[role]:selected}));
  return selected;
}
