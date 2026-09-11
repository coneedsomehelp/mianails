// Run: node tests/owner_calendar.cjs. Uses isolated sample data; never connects to Supabase.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
const script=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1].split('/* ---------- boot & routing ---------- */')[0];
new Function(script);
const nodes=new Map();
const element=id=>{if(!nodes.has(id))nodes.set(id,{id,style:{},innerHTML:'',textContent:'',hidden:false,value:'',disabled:false,classList:{add(){},remove(){},contains(){return false},toggle(){}},showModal(){this.open=true},close(){this.open=false},scrollIntoView(){}});return nodes.get(id)};
const context=vm.createContext({console,assert,document:{getElementById:element,querySelectorAll:()=>[],querySelector:()=>null,hidden:false},location:{search:'',pathname:'/'},supabase:{createClient:()=>({})},setInterval:()=>0,setTimeout:()=>0,confirm:()=>true,Intl,Date,URLSearchParams,crypto:require('node:crypto').webcrypto});
vm.runInContext(script+`
(async()=>{
  const emp='test-employee',day='2026-09-08';
  employees=[{id:emp,name:'Sample',active:true}]; shops=[{id:1,name:'Salon'}];
  ADMIN.user={id:'owner'};managersList=[{user_id:'owner',role:'owner'}];
  let snapshot={punches:[],corrections:[],leave:[]}, calls=[], fail=false;
  sb.rpc=async(name,args)=>{
    calls.push({name,args});
    if(name==='owner_calendar_get')return {data:{ok:true,version:'revision-1',snapshot}};
    if(fail)return {error:{message:'connection lost'}};
    return {data:{ok:true,audit_id:'saved'}};
  };
  ADMIN.refresh=async()=>{};
  await ADMIN.openDayEditor(emp,day);
  assert.equal(ADMIN._dayDraft.rows.length,0); assert.equal(ADMIN.dayEditorResult().minutes,0);
  assert(document.getElementById('ownerDaySessions').innerHTML.includes('value="00:00"'));
  assert(document.getElementById('ownerDaySave').disabled);
  ADMIN.updateDayEditorSession(0,'in','10:00'); assert(ADMIN.dayEditorResult().error);
  ADMIN.updateDayEditorSession(0,'out','19:30'); assert.equal(ADMIN.dayEditorResult().minutes,570);
  assert.equal(document.getElementById('ownerDayIncomplete-0').hidden,true);
  ADMIN.setDayEditorType('am'); assert.equal(ADMIN.dayEditorResult().minutes,570);
  ADMIN.addDayEditorSession(); ADMIN.updateDayEditorSession(1,'in','12:00'); ADMIN.updateDayEditorSession(1,'out','14:00');
  assert(ADMIN.dayEditorResult().error.includes('chevauchent'));
  ADMIN.removeDayEditorSession(1); ADMIN.updateDayEditorSession(0,'out','09:00'); assert(ADMIN.dayEditorResult().error);
  ADMIN.setDayEditorType('pto'); assert.equal(ADMIN.dayEditorResult().minutes,0); assert(document.getElementById('ownerDayWork').hidden);
  ADMIN.clearOwnerDay(); assert.equal(ADMIN._dayDraft.type,'pto');
  assert(document.getElementById('ownerDayConfirm').open);
  document.getElementById('ownerDayConfirm').close();
  assert.equal(calls.filter(c=>c.name==='owner_calendar_save').length,0);
  await ADMIN.confirmClearOwnerDay();
  let saved=calls.filter(c=>c.name==='owner_calendar_save').at(-1).args;
  assert.equal(saved.p_type,'clear'); assert.equal(saved.p_sessions.length,0); assert.equal(saved.p_note,null);
  assert.equal(ADMIN._dayDraft,null);
  // Two split visits retain the break; a voided original never reappears.
  snapshot.punches=[['a','10:00','in'],['b','13:00','out'],['c','14:00','in'],['d','19:30','out'],['voided','09:00','in']]
    .map(([id,time,type])=>({id,employee_id:emp,shop_id:1,type,ts:new Date(parisToTs(day,time)).toISOString()}));
  snapshot.corrections=[{kind:'void',punch_id:'voided'}];
  await ADMIN.openDayEditor(emp,day); assert.equal(ADMIN.dayEditorResult().minutes,510); assert.equal(ADMIN._dayDraft.rows.length,2);
  ADMIN.updateDayEditorSession(0,'in','10:30'); ADMIN.reviewDayEditor();
  fail=true; await ADMIN.submitDayEditor();
  const request1=calls.at(-1).args.p_request_id;
  assert(ADMIN._dayDraft); assert(!document.getElementById('ownerDaySave').disabled);
  fail=false; await ADMIN.submitDayEditor(); assert.equal(calls.at(-1).args.p_request_id,request1,'Retry must reuse request id');
  // Half-day work payload and note survive the review step.
  await ADMIN.openDayEditor(emp,day); ADMIN.setDayEditorType('am'); ADMIN._dayDraft.note='optional';
  await ADMIN.submitDayEditor(); assert(ADMIN._dayDraft.reviewed);
  await ADMIN.submitDayEditor(); saved=calls.at(-1).args;
  assert.equal(saved.p_type,'am'); assert.equal(saved.p_sessions.length,2); assert.equal(saved.p_note,'optional');
  // Cancelling deletion leaves the draft unchanged.
  await ADMIN.openDayEditor(emp,day); ADMIN.clearOwnerDay(); ADMIN.setDayEditorType('work');
  assert.equal(ADMIN._dayDraft.reviewed,false); document.getElementById('ownerDayConfirm').close(); ADMIN.closeDayEditor();
  const start=calls.length; managersList[0].role='manager'; await ADMIN.openDayEditor(emp,day);
  assert.equal(calls.length,start); assert.equal(ADMIN._dayDraft,null);
  assert(calendarError({message:'day_changed'}).includes('rور')===false);
  assert(calendarError({message:'day_changed'}).includes('rouvrez'));
  // Snapshot-only missing check-out and genuine midnight values.
  snapshot={punches:[{id:'missing',employee_id:emp,shop_id:1,type:'in',ts:new Date(parisToTs(day,'00:00')).toISOString()}],corrections:[],leave:[]};
  let d=calendarDraftFromSnapshot(snapshot,emp,day); assert.equal(d.rows[0].in,'00:00'); assert.equal(d.rows[0].out,null);
  // Adjacent out/in events must pair correctly even if input order is reversed.
  const adjacent=[['b','13:00','in'],['a','10:00','in'],['c','13:00','out'],['d','19:30','out']]
    .map(([id,time,type])=>({id,empId:emp,shop:1,type,ts:parisToTs(day,time)}));
  assert.equal(buildSessions(adjacent,[]).sessions.reduce((n,r)=>n+sessMin(r),0),570);
  // Cleared date is labelled and owner can navigate beyond the former 3-month cap.
  const md={events:[],corrections:[{id:'clear',kind:'day-edit',empId:emp,dayDate:day,details:{request:{type:'clear'}}}]};
  monthData=async()=>md;
  ADMIN.setSheetMonth('2026-09'); await ADMIN.renderSheet();
  assert(!document.getElementById('sheetCal').innerHTML.includes('cal-editable'));
  managersList[0].role='owner'; await ADMIN.renderSheet();
  assert(document.getElementById('sheetCal').innerHTML.includes('cal-editable'));
  assert(document.getElementById('sheetCal').innerHTML.includes('Đã xóa'));
  // An owner day-off correction must not infer absences elsewhere in the week.
  leave=[{type:'dayoff',empId:emp,date:day}];
  md.corrections=[{kind:'day-edit',empId:emp,dayDate:day,details:{request:{type:'dayoff'}}}];
  await ADMIN.renderSheet();
  assert(!document.getElementById('sheetCal').innerHTML.includes('Vắng'));
  assert(isRosterDayOff(leave[0],[])===true,'Existing weekly roster behavior remains');
  corrections=md.corrections;
  events=[{empId:emp,ts:parisToTs('2026-09-01','10:00')}];
  assert.equal(buildNoShows([],new Set()).length,0);
  ADMIN.setSheetMonth('2024-01'); await ADMIN.renderSheet(); assert.equal(document.getElementById('sheetMonthPicker').value,'2024-01');
  console.log('PASS: calendar draft, clear-day confirmation, hours validation, half-day payloads, immutable snapshot display, manager restriction, retries, adjacent visits, historical calendar.');
})().catch(e=>{console.error(e);process.exitCode=1});
`,vm.createContext({...context,process}));
