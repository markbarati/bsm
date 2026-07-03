const $ = (s, root=document) => root.querySelector(s);
const $$ = (s, root=document) => [...root.querySelectorAll(s)];
const state = { me:null, csrf:'', config:null, containers:[], jobs:[], page:'dashboard', wizardStep:1, activeJob:null, source:null, jobPoll:null, aiConfig:null, aiContext:null };

const PAGE_META = {
  dashboard:['داشبورد','نمای کلی سلامت و وضعیت سرور'],
  wizard:['راه‌اندازی','تنظیم مرحله‌ای شبکه، RDP و بکاپ'],
  catalog:['سرویس‌ها','انتخاب و نصب سرویس‌های Docker'],
  containers:['کانتینرها','مدیریت وضعیت و مشاهده لاگ‌ها'],
  jobs:['عملیات و لاگ زنده','نمایش پیشرفت و خروجی اجرای دستورات'],
  ledger:['تاریخچه تغییرات','ثبت Sanitized تمام عملیات مدیریتی'],
  backup:['بکاپ و بازیابی','Remote storage، تست Restore و وضعیت بکاپ'],
  updates:['به‌روزرسانی','Stage و Apply نسخه‌های جدید پنل'],
  ai:['دستیار AI','ارسال انتخابی و پاک‌سازی‌شده وضعیت سرور به سرویس AI'],
  diagnostics:['عیب‌یابی','ساخت Support Bundle قابل دانلود'],
  docs:['راهنما','معماری، امنیت و روش‌های دسترسی'],
  settings:['تنظیمات','امنیت حساب و عملیات نگهداری'],
};

const CATALOG = [
  ['portainer','Portainer','مدیریت گرافیکی Docker','PT'],
  ['homepage','Homepage','داشبورد لینک‌ها و سرویس‌ها','HP'],
  ['filebrowser','File Browser','مدیریت فایل تحت وب','FB'],
  ['uptime-kuma','Uptime Kuma','مانیتورینگ Availability','UK'],
  ['dozzle','Dozzle','مشاهده زنده Docker logs','DZ'],
  ['beszel','Beszel','مانیتور سبک سرور','BZ'],
  ['gitea','Gitea','Git خصوصی و سبک','GT'],
  ['vaultwarden','Vaultwarden','مدیریت رمز عبور','VW'],
  ['it-tools','IT-Tools','ابزارهای شبکه و توسعه','IT'],
  ['stirling-pdf','Stirling PDF','ابزارهای کامل PDF','PDF'],
  ['webtop','Webtop XFCE','دسکتاپ Ubuntu در مرورگر','WEB'],
  ['rdesktop','RDP XFCE','اتصال Windows Remote Desktop','RDP'],
];

function toast(message, type='') {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  $('#toast-root').appendChild(el);
  setTimeout(()=>el.remove(), 4500);
}

async function api(path, options={}) {
  const opts = {...options};
  opts.headers = {...(opts.headers||{})};
  if (state.csrf && !['GET','HEAD'].includes((opts.method||'GET').toUpperCase())) opts.headers['X-CSRF-Token'] = state.csrf;
  if (opts.body && !(opts.body instanceof FormData) && typeof opts.body !== 'string') {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(opts.body);
  }
  const res = await fetch(path, opts);
  if (res.status === 401) { showLogin(); throw new Error('نشست منقضی شده است'); }
  const contentType = res.headers.get('content-type') || '';
  const data = contentType.includes('json') ? await res.json() : await res.text();
  if (!res.ok) throw new Error(data.detail || data.error || data || `HTTP ${res.status}`);
  return data;
}

function fmtBytes(n) {
  if (!Number.isFinite(n)) return '—';
  const units=['B','KB','MB','GB','TB']; let i=0; let v=n;
  while (v>=1024 && i<units.length-1){v/=1024;i++;}
  return `${v.toFixed(v>=10||i===0?0:1)} ${units[i]}`;
}
function esc(v=''){return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function statusClass(s=''){s=s.toLowerCase();return s==='active'||s==='running'?'status-ok':(s.includes('failed')||s==='exited'||s==='dead'?'status-bad':'status-warn');}

function showLogin() {
  state.me=null; state.csrf='';
  $('#app-view').classList.add('hidden');
  $('#login-view').classList.remove('hidden');
}
function showApp() {
  $('#login-view').classList.add('hidden');
  $('#app-view').classList.remove('hidden');
  $('#username').textContent=state.me.username;
}

async function init() {
  bindEvents();
  try {
    state.me = await api('/api/me'); state.csrf=state.me.csrf; showApp();
    await Promise.allSettled([loadDashboard(), loadConfig(), loadJobs()]);
  } catch { showLogin(); }
}

function bindEvents() {
  $('#login-form').addEventListener('submit', async e=>{
    e.preventDefault(); const f=new FormData(e.target);
    try { const d=await api('/api/auth/login',{method:'POST',body:{username:f.get('username'),password:f.get('password')}}); state.me=d;state.csrf=d.csrf;showApp();await Promise.all([loadDashboard(),loadConfig(),loadJobs()]); }
    catch(err){toast(err.message,'error');}
  });
  $('#logout-btn').onclick=async()=>{try{await api('/api/auth/logout',{method:'POST',body:{}});}catch{}showLogin();};
  $$('#nav button').forEach(b=>b.onclick=()=>go(b.dataset.page));
  $$('[data-goto]').forEach(b=>b.onclick=()=>go(b.dataset.goto));
  $('#refresh-btn').onclick=refreshCurrent;
  $('#quick-verify').onclick=()=>startTask('verify');
  $('#containers-refresh').onclick=loadContainers;
  $('#ledger-refresh').onclick=loadLedger;
  $('#updates-refresh').onclick=loadUpdates;
  $('#diagnostics-btn').onclick=createDiagnostics;
  $('#clear-log').onclick=()=>$('#live-log').textContent='';
  $('#modal-close').onclick=()=>$('#modal').close();
  $('#wizard-next').onclick=()=>setWizard(Math.min(5,state.wizardStep+1));
  $('#wizard-prev').onclick=()=>setWizard(Math.max(1,state.wizardStep-1));
  $$('.wizard-steps button').forEach(b=>b.onclick=()=>setWizard(Number(b.dataset.step)));
  $('#wizard-form').addEventListener('submit', saveWizard);
  $('#catalog-apply').onclick=applyCatalog;
  $('#update-form').addEventListener('submit', uploadUpdate);
  $('#password-form').addEventListener('submit', changePassword);
  $('#ai-config-form').addEventListener('submit', saveAIConfig);
  $('#ai-provider').addEventListener('change', toggleAIBaseUrl);
  $('#ai-preview').onclick=previewAIContext;
  $('#ai-copy-context').onclick=copyAIContext;
  $('#ai-chat-form').addEventListener('submit', askAI);
  $('#ai-clear').onclick=()=>{$('#ai-messages').innerHTML='<div class="ai-message assistant">گفتگو پاک شد. Context سرور فقط هنگام ارسال بعدی ساخته می‌شود.</div>';};
  $$('#page-ai input, #page-ai select').forEach(el=>el.addEventListener('change',()=>{state.aiContext=null;}));
  $$('[data-task]').forEach(b=>b.onclick=()=>startTask(b.dataset.task));
}

function go(page) {
  state.page=page;
  $$('.page').forEach(p=>p.classList.remove('active'));
  $(`#page-${page}`).classList.add('active');
  $$('#nav button').forEach(b=>b.classList.toggle('active',b.dataset.page===page));
  $('#page-title').textContent=PAGE_META[page][0]; $('#page-subtitle').textContent=PAGE_META[page][1];
  if(page==='containers')loadContainers(); if(page==='jobs')loadJobs(); if(page==='ledger')loadLedger(); if(page==='updates')loadUpdates(); if(page==='catalog')renderCatalog(); if(page==='wizard')fillWizard(); if(page==='ai')loadAI();
}
function refreshCurrent(){({dashboard:loadDashboard,containers:loadContainers,jobs:loadJobs,ledger:loadLedger,updates:loadUpdates,ai:loadAI}[state.page]||loadDashboard)();}

async function loadDashboard() {
  try {
    const d=await api('/api/dashboard');
    $('#agent-dot').className='dot ok'; $('#agent-text').textContent='Agent Online';
    const loadPct=Math.min(100,(d.load[0]/Math.max(d.cpu_count,1))*100);
    const ramPct=d.memory.total?d.memory.used/d.memory.total*100:0; const diskPct=d.disk.total?d.disk.used/d.disk.total*100:0;
    $('#cpu-value').textContent=`${d.load[0].toFixed(2)} / ${d.cpu_count}`; $('#cpu-bar').style.width=`${loadPct}%`;
    $('#ram-value').textContent=`${fmtBytes(d.memory.used)} / ${fmtBytes(d.memory.total)}`; $('#ram-bar').style.width=`${ramPct}%`;
    $('#disk-value').textContent=`${fmtBytes(d.disk.used)} / ${fmtBytes(d.disk.total)}`; $('#disk-bar').style.width=`${diskPct}%`;
    $('#containers-value').textContent=`${d.containers.running} / ${d.containers.total}`; $('#containers-note').textContent=d.containers.unhealthy?`${d.containers.unhealthy} unhealthy`:'همه سالم';
    $('#service-health').classList.remove('skeleton');
    $('#service-health').innerHTML=Object.entries(d.services).map(([k,v])=>`<div class="health-item"><b>${esc(k)}</b><span class="${statusClass(v)}">${esc(v)}</span></div>`).join('');
    $('#server-info').innerHTML=[['Hostname',d.hostname],['Architecture',d.architecture],['Kernel',d.kernel],['Updated',new Date(d.timestamp).toLocaleString('fa-IR')]].map(([k,v])=>`<div><dt>${k}</dt><dd>${esc(v)}</dd></div>`).join('');
    await loadContainers(true);
  } catch(err){$('#agent-dot').className='dot bad';$('#agent-text').textContent='Agent Offline';toast(err.message,'error');}
}

async function loadContainers(dashboardOnly=false) {
  try { state.containers=await api('/api/containers');
    $('#dashboard-containers').innerHTML=state.containers.slice(0,8).map(c=>`<div class="container-card"><b>${esc(c.name)}</b><span class="${statusClass(c.state)}">${esc(c.status)}</span></div>`).join('')||'<p>کانتینری یافت نشد.</p>';
    if(!dashboardOnly) renderContainers();
  } catch(err){toast(err.message,'error');}
}
function renderContainers(){
  $('#containers-table').innerHTML=state.containers.map(c=>`<tr><td><b>${esc(c.name)}</b></td><td class="ltr">${esc(c.image)}</td><td><span class="status-pill ${statusClass(c.state)}">${esc(c.status)}</span></td><td class="ltr">${esc(c.cpu||'—')}</td><td class="ltr">${esc(c.memory||'—')}</td><td class="ltr">${esc(c.ports||'—')}</td><td><div class="table-actions"><button class="btn ghost" onclick="containerAction('${esc(c.name)}','start')">Start</button><button class="btn ghost" onclick="containerAction('${esc(c.name)}','restart')">Restart</button><button class="btn danger" onclick="containerAction('${esc(c.name)}','stop')">Stop</button><button class="btn secondary" onclick="showContainerLogs('${esc(c.name)}')">Logs</button></div></td></tr>`).join('');
}
window.containerAction=async(name,action)=>{try{await api(`/api/containers/${encodeURIComponent(name)}/${action}`,{method:'POST',body:{}});toast(`${name}: ${action}`,'success');setTimeout(loadContainers,800);}catch(e){toast(e.message,'error')}};
window.showContainerLogs=async(name)=>{try{const d=await api(`/api/containers/${encodeURIComponent(name)}/logs?tail=500`);openModal(`Logs: ${name}`,`<pre>${esc(d.logs)}</pre>`);}catch(e){toast(e.message,'error')}};

async function loadConfig(){try{state.config=await api('/api/config');renderCatalog();fillWizard();}catch(e){toast(e.message,'error')}}
function renderCatalog(){
  if(!state.config)return;
  $('#app-catalog').innerHTML=CATALOG.map(([id,title,desc,icon])=>{const on=!!state.config.apps[id];return `<label class="catalog-card ${on?'selected':''}"><input type="checkbox" data-app="${id}" ${on?'checked':''}><div class="app-icon">${icon}</div><h3>${title}</h3><p>${desc}</p><div class="app-meta"><span>ARM64</span><span>${on?'Selected':'Optional'}</span></div></label>`}).join('');
  $$('#app-catalog input').forEach(i=>i.onchange=()=>i.closest('.catalog-card').classList.toggle('selected',i.checked));
}
async function applyCatalog(){
  if(!state.config)return; $$('#app-catalog input').forEach(i=>state.config.apps[i.dataset.app]=i.checked);
  try{await api('/api/config',{method:'PUT',body:state.config});toast('انتخاب سرویس‌ها ذخیره شد','success');await startTask('reconcile');}catch(e){toast(e.message,'error')}
}

function setWizard(step){state.wizardStep=step;$$('.wizard-pane').forEach(p=>p.classList.toggle('active',Number(p.dataset.pane)===step));$$('.wizard-steps button').forEach(b=>b.classList.toggle('active',Number(b.dataset.step)===step));$('#wizard-prev').classList.toggle('hidden',step===1);$('#wizard-next').classList.toggle('hidden',step===5);$('#wizard-save').classList.toggle('hidden',step!==5);if(step===5)renderReview();}
function setField(name,value){const el=$(`[name="${name}"]`);if(!el)return;if(el.type==='checkbox')el.checked=!!value;else if(el.type==='radio')$$(`[name="${name}"]`).forEach(r=>r.checked=r.value===value);else el.value=value??'';}
function fillWizard(){if(!state.config)return;const c=state.config;setField('domain',c.domain);setField('public_ip',c.public_ip);setField('timezone',c.timezone);setField('app_owner',c.app_owner);setField('manager_hostname',c.cloudflare.manager_hostname);setField('access_email',c.cloudflare.access_email);setField('cloudflare_install',c.cloudflare.install);setField('rdp_mode',c.rdp.mode);setField('rdp_allowed_cidr',c.rdp.allowed_cidr);setField('rdp_public_port',c.ports.rdp_public);setField('webtop_user',c.secrets.webtop_user==='[SET]'?'':c.secrets.webtop_user);setField('backup_enabled',c.backup.enabled);setField('rclone_remote',c.backup.rclone_remote);setField('remote_path',c.backup.remote_path);setField('backup_hour',c.backup.hour);setField('retention_days',c.backup.retention_days);}
function formObj(){const f=new FormData($('#wizard-form'));return Object.fromEntries(f.entries());}
function renderReview(){const f=formObj();const apps=Object.entries(state.config.apps).filter(([,v])=>v).map(([k])=>k).join(', ');$('#review-box').innerHTML=[['Domain',f.domain],['Timezone',f.timezone],['Manager',f.manager_hostname],['RDP mode',f.rdp_mode],['Backup',f.backup_enabled?'Enabled':'Disabled'],['Apps',apps]].map(([a,b])=>`<div><span>${a}</span><b>${esc(b||'—')}</b></div>`).join('');}
async function saveWizard(e){e.preventDefault();const f=formObj();const c=JSON.parse(JSON.stringify(state.config));c.domain=f.domain;c.public_ip=f.public_ip;c.timezone=f.timezone;c.app_owner=f.app_owner;c.cloudflare.manager_hostname=f.manager_hostname;c.cloudflare.access_email=f.access_email;c.cloudflare.install=!!$('[name=cloudflare_install]').checked;c.rdp.mode=f.rdp_mode;c.rdp.allowed_cidr=f.rdp_allowed_cidr;c.ports.rdp_public=Number(f.rdp_public_port||8888);c.backup.enabled=!!$('[name=backup_enabled]').checked;c.backup.rclone_remote=f.rclone_remote;c.backup.remote_path=f.remote_path;c.backup.hour=f.backup_hour;c.backup.retention_days=Number(f.retention_days||14);c.secrets={};if(f.cloudflare_tunnel_token)c.secrets.cloudflare_tunnel_token=f.cloudflare_tunnel_token;if(f.webtop_user)c.secrets.webtop_user=f.webtop_user;if(f.webtop_password)c.secrets.webtop_password=f.webtop_password;if(f.rdp_password)c.secrets.rdp_password=f.rdp_password;try{state.config=await api('/api/config',{method:'PUT',body:c});toast('تنظیمات ذخیره شد','success');await startTask('reconcile');}catch(err){toast(err.message,'error')}}

async function startTask(task){
  try{const job=await api('/api/jobs',{method:'POST',body:{task}});toast(`Job ${task} شروع شد`,'success');go('jobs');await loadJobs();watchJob(job.id);}catch(e){toast(e.message,'error')}
}
async function loadJobs(){try{state.jobs=await api('/api/jobs');renderJobs();}catch(e){toast(e.message,'error')}}
function renderJobs(){
  $('#jobs-list').innerHTML=state.jobs.map(j=>`<div class="job-card ${state.activeJob===j.id?'active':''}" data-job="${j.id}"><div class="row"><b>${esc(j.task)}</b><span class="status-pill ${j.status==='success'?'status-ok':j.status==='failed'?'status-bad':'status-warn'}">${esc(j.status)}</span></div><small>${esc(j.message||'')} · ${new Date(j.created_at).toLocaleString('fa-IR')}</small><div class="job-progress"><i style="width:${Number(j.progress||0)}%"></i></div></div>`).join('')||'<p>عملیاتی ثبت نشده است.</p>';
  $$('.job-card').forEach(e=>e.onclick=()=>watchJob(e.dataset.job));
}
function watchJob(id){
  state.activeJob=id;renderJobs();
  if(state.source)state.source.close(); if(state.jobPoll)clearInterval(state.jobPoll);
  $('#live-log').textContent='';$('#live-log-title').textContent=`Job ${id}`;
  let offset=0, failedOver=false;
  const applyChunk=d=>{if(d.chunk){const pre=$('#live-log');pre.textContent+=d.chunk;pre.scrollTop=pre.scrollHeight;offset=d.next_offset||offset;}if(d.job){const i=state.jobs.findIndex(x=>x.id===d.job.id);if(i>=0)state.jobs[i]=d.job;else state.jobs.unshift(d.job);renderJobs();if(['success','failed'].includes(d.job.status)&&!d.chunk){if(state.source)state.source.close();if(state.jobPoll)clearInterval(state.jobPoll);loadDashboard();}}};
  const poll=()=>{if(failedOver)return;failedOver=true;if(state.source)state.source.close();const tick=async()=>{try{const d=await api(`/api/jobs/${id}/log?offset=${offset}`);applyChunk(d);}catch(e){clearInterval(state.jobPoll);toast(e.message,'error')}};tick();state.jobPoll=setInterval(tick,1200);};
  try{const src=new EventSource(`/api/jobs/${id}/stream`);state.source=src;src.onmessage=e=>applyChunk(JSON.parse(e.data));src.onerror=poll;}catch{poll();}
}

async function loadLedger(){try{const items=await api('/api/ledger?limit=400');$('#ledger-list').innerHTML=items.map(x=>{const cmd=Array.isArray(x.argv)?x.argv.join(' '):x.argv||'';return `<details class="ledger-entry"><summary><span>${new Date(x.timestamp).toLocaleString('fa-IR')}</span><span>${esc(x.actor||'system')}</span><code>${esc(cmd)}</code><span class="${Number(x.exit_code)===0?'status-ok':'status-bad'}">exit ${esc(x.exit_code)}</span></summary><pre>${esc(JSON.stringify(x,null,2))}</pre></details>`}).join('')||'<p>هنوز رکوردی وجود ندارد.</p>';}catch(e){toast(e.message,'error')}}

async function uploadUpdate(e){e.preventDefault();const file=$('#update-file').files[0];if(!file)return;const fd=new FormData();fd.append('file',file);try{const d=await api('/api/updates/upload',{method:'POST',body:fd});toast(`نسخه ${d.manifest.version} Stage شد`,'success');loadUpdates();}catch(err){toast(err.message,'error')}}
async function loadUpdates(){try{const [list,releases]=await Promise.all([api('/api/updates'),api('/api/releases')]);$('#updates-list').innerHTML=list.map(u=>`<div class="update-card"><div><b>${esc(u.manifest?.name||u.manifest?.kind)} ${esc(u.manifest?.version||'')}</b><small> · ${esc(u.status)} · SHA ${esc((u.sha256||'').slice(0,12))}</small></div>${u.status==='staged'?`<button class="btn primary" onclick="applyUpdate('${u.id}')">Apply</button>`:''}</div>`).join('')||'<p>نسخه Stage شده‌ای وجود ندارد.</p>';$('#releases-list').innerHTML=releases.map(r=>`<div class="update-card"><div><b>Version ${esc(r.version)}</b><small> · ${r.active?'Active':'Available'} · ${new Date(r.modified_at).toLocaleString('fa-IR')}</small></div>${r.active?'<span class="status-pill status-ok">ACTIVE</span>':`<button class="btn ghost" onclick="rollbackRelease('${esc(r.version)}')">Rollback</button>`}</div>`).join('')||'<p>Release ثبت‌شده‌ای یافت نشد.</p>';}catch(e){toast(e.message,'error')}}

window.rollbackRelease=async version=>{const phrase=prompt('برای فعال‌کردن نسخه قبلی عبارت ROLLBACK را وارد کن:');if(phrase!=='ROLLBACK')return;try{await api(`/api/releases/${encodeURIComponent(version)}/activate`,{method:'POST',body:{confirm:phrase}});toast(`Rollback به ${version} زمان‌بندی شد`,'success');setTimeout(()=>location.reload(),8000);}catch(e){toast(e.message,'error')}};

window.applyUpdate=async id=>{const phrase=prompt('برای اعمال نسخه جدید عبارت APPLY UPDATE را وارد کن:');if(phrase!=='APPLY UPDATE')return;try{await api(`/api/updates/${id}/apply`,{method:'POST',body:{confirm:phrase}});toast('به‌روزرسانی زمان‌بندی شد. صفحه ممکن است موقتاً قطع شود.','success');setTimeout(()=>location.reload(),8000);}catch(e){toast(e.message,'error')}};


function selectedValues(selector){return [...$(selector).selectedOptions].map(o=>o.value);}
function aiContextOptions(){return {anonymize:$('#ctx-anonymize').checked,system:$('#ctx-system').checked,containers:$('#ctx-containers').checked,config:$('#ctx-config').checked,ledger:$('#ctx-ledger').checked,ledger_lines:160,container_logs:selectedValues('#ai-container-select'),service_logs:selectedValues('#ai-service-select')};}
function toggleAIBaseUrl(){const custom=$('#ai-provider').value==='openai-compatible';$('#ai-base-url-row').classList.toggle('hidden',!custom);}
async function loadAI(){
  try{
    const [cfg,containers]=await Promise.all([api('/api/ai/config'),api('/api/containers')]);
    state.aiConfig=cfg;state.containers=containers;
    $('#ai-provider').value=cfg.provider||'openai';$('#ai-model').value=cfg.model||'';$('#ai-base-url').value=cfg.base_url||'';
    $('[name=timeout_seconds]').value=cfg.timeout_seconds||90;$('[name=max_context_chars]').value=cfg.max_context_chars||120000;
    $('#ai-key-status').textContent=cfg.api_key==='[SET]'?'API key stored':'Not configured';$('#ai-key-status').className=`status-pill ${cfg.api_key==='[SET]'?'status-ok':'status-warn'}`;
    $('#ai-container-select').innerHTML=containers.map(c=>`<option value="${esc(c.name)}">${esc(c.name)} — ${esc(c.status)}</option>`).join('');
    toggleAIBaseUrl();
  }catch(e){toast(e.message,'error')}
}
async function saveAIConfig(e){
  e.preventDefault();const f=new FormData(e.target);
  const body={provider:f.get('provider'),model:f.get('model'),base_url:f.get('base_url'),api_key:f.get('api_key'),clear_api_key:f.get('clear_api_key')==='on',timeout_seconds:Number(f.get('timeout_seconds')),max_context_chars:Number(f.get('max_context_chars'))};
  try{state.aiConfig=await api('/api/ai/config',{method:'PUT',body});$('#ai-api-key').value='';$('#ai-clear-key').checked=false;toast('تنظیمات AI ذخیره شد','success');await loadAI();}catch(err){toast(err.message,'error')}
}
async function previewAIContext(){
  try{const d=await api('/api/ai/context',{method:'POST',body:aiContextOptions()});state.aiContext=d;$('#ai-context-meta').classList.remove('hidden');$('#ai-context-meta').innerHTML=`<b>${d.characters.toLocaleString()} characters</b> · ${d.anonymized?'network anonymized':'network identifiers retained'} · ${d.sections.map(esc).join('، ')} ${d.truncated?'· <span class="danger">truncated</span>':''}<details><summary>نمایش متن دقیق ارسالی</summary><pre class="terminal">${esc(d.text)}</pre></details>`;toast('Context ساخته شد؛ قبل از ارسال آن را بررسی کن.','success');}catch(e){toast(e.message,'error')}
}
async function copyAIContext(){
  try{if(!state.aiContext)await previewAIContext();if(!state.aiContext)return;await navigator.clipboard.writeText(state.aiContext.text);toast('Context پاک‌سازی‌شده کپی شد','success');}catch(e){toast(e.message,'error')}
}
function addAIMessage(role,text){const el=document.createElement('div');el.className=`ai-message ${role}`;el.textContent=text;$('#ai-messages').appendChild(el);$('#ai-messages').scrollTop=$('#ai-messages').scrollHeight;return el;}
async function askAI(e){
  e.preventDefault();const q=$('#ai-question').value.trim();if(!q)return;
  addAIMessage('user',q);$('#ai-question').value='';const thinking=addAIMessage('assistant ai-thinking','در حال ساخت Context پاک‌سازی‌شده و دریافت پاسخ…');
  try{const d=await api('/api/ai/ask',{method:'POST',body:{question:q,context:aiContextOptions(),context_snapshot:state.aiContext?.text||''}});thinking.classList.remove('ai-thinking');thinking.textContent=d.answer;const meta=document.createElement('small');meta.textContent=`${d.provider} / ${d.model} · ${d.context.characters.toLocaleString()} chars`;thinking.appendChild(document.createElement('br'));thinking.appendChild(meta);state.aiContext=null;}catch(err){thinking.className='ai-message error';thinking.textContent=err.message;}
}

async function createDiagnostics(){try{const d=await api('/api/diagnostics',{method:'POST',body:{}});$('#diag-result').innerHTML=`<div class="callout info">فایل آماده شد: <a class="btn secondary" href="/api/diagnostics/${d.id}">دانلود ${esc(d.filename)}</a></div>`;toast('Diagnostic Bundle ساخته شد','success');}catch(e){toast(e.message,'error')}}
async function changePassword(e){e.preventDefault();const f=new FormData(e.target);try{const d=await api('/api/change-password',{method:'POST',body:{current:f.get('current'),new:f.get('new')}});toast(d.message,'success');setTimeout(showLogin,1200);}catch(err){toast(err.message,'error')}}
function openModal(title,html){$('#modal-title').textContent=title;$('#modal-body').innerHTML=html;$('#modal').showModal();}

document.addEventListener('DOMContentLoaded',()=>{init();setInterval(()=>{if(state.me&&state.page==='dashboard')loadDashboard();},15000);});
