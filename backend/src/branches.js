import {HTTPError,required} from './rules.js';
import {readConfiguration,updateConfiguration} from './access.js';

// Addresses from NIBM's published contact directory, checked 30 October 2026.
// Coordinates are supplied by an Administrator or resolved on-device from the address.
export const campuses=[
  ['colombo','Colombo Campus','120/5 Vidya Mawatha, Colombo 7, Sri Lanka'],
  ['rajagiriya','Rajagiriya Campus','241 Castle Street, Colombo 08, Sri Lanka'],
  ['kandy','Kandy Campus','2 Asgiri Vihara Mawatha, Kandy, Sri Lanka'],
  ['kurunegala','Kurunegala Campus','47 Bauddhaloka Mawatha, Kurunegala, Sri Lanka'],
  ['galle','Galle Campus','132 Samudhra Mawatha, Galle, Sri Lanka'],
  ['matara','Matara Campus','26 Anagarika Dharmapala Mawatha, Matara, Sri Lanka'],
  ['kirulapone','Kirulapone NIC','24 Edmonton Road, Colombo 05, Sri Lanka'],
  ['peradeniya','Kandy KIC','1117 Sirimavo Bandaranayake Mawatha, Getambe, Peradeniya, Sri Lanka']
].map(([id,name,address])=>({id,name,address}));
export async function branchDirectory(db){
  const locations=await readConfiguration(db,'branch-locations',{});
  const rows=await db.query('SELECT id,description FROM branch WHERE status=1 ORDER BY description');
  return{branches:rows.map(row=>({id:row.id,name:row.description,address:locations[row.id]?.address??campuses.find(c=>c.name.toLowerCase().includes(row.description.toLowerCase()))?.address??'',coordinate:locations[row.id]?.coordinate??null})),campuses,sourceURL:'https://nibm.ac.lk/contact'};
}
export async function saveBranchLocation(db,value,input){
  const id=Number(value);
  if(!Number.isInteger(id)||id<1||!(await db.query('SELECT id FROM branch WHERE id=? AND status=1',[id])).length)throw new HTTPError(404,'Branch not found.');
  const {latitude,longitude}=input.coordinate??{};
  if(!Number.isFinite(latitude)||!Number.isFinite(longitude)||Math.abs(latitude)>90||Math.abs(longitude)>180)throw new HTTPError(400,'Select a valid map point.');
  const address=required(input.address,'branch address',512);
  await updateConfiguration(db,'branch-locations',current=>({...current,[id]:{address,coordinate:{latitude,longitude}}}));
}
