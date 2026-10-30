import {readFile,mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve,join} from 'node:path';
import {loadEnvironment,loadConfig} from '../src/config.js';
import {database,migrate} from '../src/db.js';
import {backupTables} from '../src/backup-schema.js';
import {readConfiguration,updateConfiguration} from '../src/access.js';

loadEnvironment();
const config=loadConfig();
if(config.database.name!=='nibm_one_ios')throw Error('Reference import is scoped to nibm_one_ios. No changes made.');
const dataset=JSON.parse(await readFile(new URL('../data/institution-reference.json',import.meta.url),'utf8'));
let db;
try{
  db=database(config.database);await db.sequelize.authenticate();
  const source=dataset.records;
  const branchIDs=new Set(source.branch.map(row=>row[0])),departmentIDs=new Set(source.department.map(row=>row[0]));
  if(source.companybranch.some(row=>!branchIDs.has(row[2]))||source.branchdepartment.some(row=>!branchIDs.has(row[2])||!departmentIDs.has(row[3])))throw Error('Source data contains unresolved foreign keys.');
  const locations=await readConfiguration(db,'branch-locations',{});
  const [oldColombo]=await db.query('SELECT * FROM branch WHERE id=?',[33]);
  const relocate=oldColombo?.description==='Colombo';
  if(oldColombo&&!['Colombo','Rathnapura'].includes(oldColombo.description))throw Error('Unexpected existing branch 33. No master data was changed.');
  if(relocate&&locations['33']&&locations['1'])throw Error('Both old and canonical Colombo pins exist. Resolve the pin conflict before importing.');
  const audit=resolve(fileURLToPath(new URL('../storage/',import.meta.url)),config.database.name,'imports');
  await mkdir(audit,{recursive:true});
  const before={};
  for(const table of ['branch','department','company','companybranch'])before[table]=await db.query('SELECT * FROM '+table);
  await writeFile(join(audit,'reference-before-'+new Date().toISOString().replaceAll(':','-')+'.json'),JSON.stringify({before,branchLocations:locations},null,2),{mode:0o600});
  await migrate(db); // Includes the exact requested branchdepartment definition; existing tables are not altered.
  const quote=name=>db.sequelize.getQueryInterface().queryGenerator.quoteIdentifier(name);
  async function upsert(tx,table,rows){
    const ddl=backupTables.find(value=>value.name===table)?.ddl;if(!ddl)throw Error('Unapproved reference table');
    const columns=[...ddl.matchAll(/^\s+`([^`]+)`/gm)].map(match=>match[1]);
    const keys=[.../PRIMARY KEY \(([^)]+)\)/.exec(ddl)[1].matchAll(/`([^`]+)`/g)].map(match=>match[1]);
    const updates=columns.filter(column=>!keys.includes(column));
    for(const row of rows){
      if(row.length!==columns.length)throw Error('Column count mismatch in '+table);
      await tx.query('INSERT INTO '+quote(table)+' ('+columns.map(quote).join(',')+') VALUES ('+columns.map(()=>'?').join(',')+') ON DUPLICATE KEY UPDATE '+updates.map(column=>quote(column)+'=VALUES('+quote(column)+')').join(','),row);
    }
  }
  const result=await db.transaction(async tx=>{
    await upsert(tx,'company',source.company);
    await upsert(tx,'branch',source.branch.filter(row=>row[0]===1));
    const moved=[];
    if(relocate){
      const references=await tx.query("SELECT TABLE_NAME AS tableName,COLUMN_NAME AS columnName FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_SCHEMA=DATABASE() AND REFERENCED_TABLE_NAME='branch' AND REFERENCED_COLUMN_NAME='id'");
      for(const reference of references){
        const changed=await tx.query('UPDATE '+quote(reference.tableName)+' SET '+quote(reference.columnName)+'=? WHERE '+quote(reference.columnName)+'=?',[1,33]);
        moved.push({table:reference.tableName,column:reference.columnName,affected:changed.affectedRows??0});
      }
    }
    await upsert(tx,'branch',source.branch);
    await upsert(tx,'department',source.department);
    await upsert(tx,'companybranch',source.companybranch);
    await upsert(tx,'branchdepartment',source.branchdepartment);
    return{imported:Object.fromEntries(Object.entries(source).map(([table,rows])=>[table,rows.length])),movedColomboReferences:moved,pendingCompanyBranchIDs:dataset.pendingCompanyBranches.map(row=>row[0])};
  });
  if(relocate&&locations['33'])await updateConfiguration(db,'branch-locations',current=>{
    const updated={...current,'1':current['33']};delete updated['33'];return updated;
  });
  await writeFile(join(audit,'reference-import-latest.json'),JSON.stringify({...result,checkedAt:new Date().toISOString()},null,2),{mode:0o600});
  console.log(JSON.stringify(result));
}catch(error){console.error(error.code??error.message);process.exitCode=1;}finally{await db?.close();}
