"use strict";
const $ = id => document.getElementById(id);
let catalog = {profiles:[],presets:[],activeId:"default"};
let selectedProfile = null;
let dirty = false;
let busy = false;
const messages = {CONFIG_VERSION_CONFLICT:"This configuration changed. Reload the page before editing again.",MODEL_CONFIG_BUSY:"An investigation is in progress. Try again after it finishes.",NEW_KEY_REQUIRED:"Enter a new key when changing the provider or endpoint.",MODEL_KEY_REQUIRED:"Enter an API key for this provider.",MODEL_RATES_REQUIRED:"Save input and output planning rates before activating this model.",INVALID_MODEL_ENDPOINT:"Use HTTPS for remote providers, or a local Ollama endpoint. URL credentials and query strings are not allowed.",MODEL_CONFIG_SAVE_FAILED:"The configuration could not be saved. Check administrator permissions and configuration values.",MODEL_ENDPOINT_FIXED:"This native provider uses its standard SDK endpoint.",INVALID_MODEL_RATES:"Enter valid nonnegative input and output rates."};

/** Render all server labels as text; never interpret configuration or model names as HTML. */
function node(tag, text, cls) {
  const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;
}

/** Write configuration through the native authenticated admin application; do not read an HTML login page as 401 error details. */
async function api(path, data) {
  const response=await fetch(path,{method:data===undefined?"GET":"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Identity-Review":"local-demo"},body:data===undefined?undefined:JSON.stringify(data)});
  if(response.status===401||response.status===403){$("api-key").value="";identityAdmin.signIn("/identity/settings");throw new Error("Administrator session expired. Please sign in again.");}
  let body;try{body=await response.json();}catch{throw new Error("The server returned an unexpected response.");}
  if(!response.ok)throw new Error(messages[body.code]||body.code||"Configuration request failed.");
  return body;
}

/** Lock selection and inputs during operations so save responses cannot overwrite a newly selected configuration or newly entered key. */
function setBusy(value) {
  busy=value;for(const e of document.querySelectorAll("#model-form input, #model-form select, #model-form button, #profiles button, #new-profile"))e.disabled=value;
  if(!value)updateControls();
}

/** Distinguish active, unsaved, and pending states; do not activate a dirty form directly. */
function updateControls() {
  const preset=catalog.presets.find(p=>p.id===$("provider").value);
  $("api-key").disabled=busy||!preset?.keyRequired;
  $("base-url").disabled=busy||(preset?.adapter!=="openai");
  $("activate-profile").disabled=busy||dirty||!selectedProfile?.id||selectedProfile.id===catalog.activeId;
  $("profile-status").textContent=dirty?"Unsaved changes":selectedProfile?.id===catalog.activeId?"Active":"Not active";
}

/** Ordinary editing must neither call a model automatically nor silently change the active selection. */
function markDirty() { dirty=true;updateControls(); }

/** Clear another model's planning rates after a model change to avoid silently inheriting inapplicable prices. */
function markModelDirty() {
  if($("model").value.trim()!==(selectedProfile?.model||"")){
    const p=catalog.presets.find(x=>x.id===$("provider").value);
    $("input-rate").value=p?.keyRequired?"":"0";$("output-rate").value=p?.keyRequired?"":"0";
  }
  markDirty();
}

/** Clear the previous model, key, and cloud rates when changing providers to avoid sending old credentials or prices to a new service. */
function applyPreset() {
  const p=catalog.presets.find(p=>p.id===$("provider").value);if(!p)return;
  $("base-url").value=p.baseURL;$("model").value="";$("api-key").value="";
  $("input-rate").value=p.keyRequired?"":"0";$("output-rate").value=p.keyRequired?"":"0";
  $("key-note").textContent=p.keyRequired?"Enter a key for this provider. A previous provider's key will not be reused.":"No provider key is required for local Ollama.";
  $("endpoint-note").textContent=p.adapter==="openai"?"Use the endpoint for your account and region.":"This native provider uses its standard SDK endpoint.";
  markDirty();
}

/** Never populate keys when switching configurations; indicate only whether a stored key exists, and use blank input to retain it. */
function showProfile(profile) {
  if(busy)return;
  selectedProfile=profile?{...profile}:null;dirty=false;
  $("label").value=profile?.label||"";$("provider").value=profile?.preset||"qwen";
  const p=catalog.presets.find(p=>p.id===$("provider").value)||catalog.presets[0];
  $("base-url").value=profile?.baseURL??p?.baseURL??"";$("model").value=profile?.model||"";$("api-key").value="";
  $("input-rate").value=profile?.rates?.input===undefined?"":String(profile.rates.input);$("output-rate").value=profile?.rates?.output===undefined?"":String(profile.rates.output);
  $("form-title").textContent=profile?.label||"New AI configuration";$("form-eyebrow").textContent=profile?.id?`${profile.id.toUpperCase()} · VERSION ${profile.version}`:"NEW CONFIGURATION";
  $("key-note").textContent=!p?.keyRequired?"No provider key is required for local Ollama.":profile?.keyStored?"A key is stored in Wallet. Leave blank to keep it, or enter a new key to replace it.":"Enter a key to store in IRIS Wallet.";
  $("api-key").placeholder=profile?.keyStored?"Key stored · leave blank to keep":"Enter API key";
  $("endpoint-note").textContent=p?.adapter==="openai"?"Use the endpoint for your account and region.":"This native provider uses its standard SDK endpoint.";
  renderProfiles();updateControls();
}

/** Show only safe configuration fields; derive activation status from the backend instead of simulating click success. */
function renderProfiles() {
  $("profiles").replaceChildren();$("profile-count").textContent=catalog.profiles.length;
  for(const profile of catalog.profiles){
    const b=node("button",undefined,"case"+(selectedProfile?.id===profile.id?" selected":""));
    b.disabled=busy;b.append(node("span",profile.id===catalog.activeId?"Active":"Saved","badge"+(profile.id===catalog.activeId?" approved":"")),node("strong",profile.label),node("span",`${profile.model||"No model"} · ${profile.preset}`,"meta"));
    b.addEventListener("click",()=>{showProfile(profile);$("settings-notice").textContent="";});$("profiles").append(b);
  }
}

/** Require rates as a pair; do not interpret empty fields as a free model. */
function readRates() {
  const a=$("input-rate").value.trim(),b=$("output-rate").value.trim();if(!a&&!b)return {};
  if(!a||!b||!Number.isFinite(Number(a))||!Number.isFinite(Number(b))||Number(a)<0||Number(b)<0)throw new Error("Enter both nonnegative planning rates, or leave both empty to save a draft.");
  return {input:Number(a),output:Number(b)};
}

/** Include a key in the save request only when nonempty; never overwrite Wallet with placeholders or empty values. */
function readForm() {
  const data={id:selectedProfile?.id||"",version:selectedProfile?.version||0,label:$("label").value.trim(),preset:$("provider").value,model:$("model").value.trim(),baseURL:$("base-url").value.trim(),rates:readRates()};
  if($("api-key").value)data.apiKey=$("api-key").value;
  return data;
}

/** Retain the server ID and version immediately after a successful write so a later refresh failure cannot misreport the save as failed. */
function rememberSaved(saved, activate=false) {
  selectedProfile={...saved};dirty=false;
  const index=catalog.profiles.findIndex(p=>p.id===saved.id);
  if(index<0)catalog.profiles.push(saved);else catalog.profiles[index]=saved;
  if(activate)catalog.activeId=saved.id;
  $("form-title").textContent=saved.label;$("form-eyebrow").textContent=`${saved.id.toUpperCase()} · VERSION ${saved.version}`;
  renderProfiles();updateControls();
}

/** Clear the entered key after every request, successful or otherwise; reload the actual list and versions after saving. */
async function saveProfile() {
  if(busy)return;$("settings-notice").textContent="";
  try{
    const data=readForm();setBusy(true);const saved=await api("/identity/admin/models",data);
    rememberSaved(saved);
    try { await load(saved.id);$("settings-notice").textContent="Configuration saved. Format validated; no model request was made."; }
    catch { $("settings-notice").textContent="Configuration saved. Status refresh failed; your saved ID and version are retained. Reload when the connection recovers."; }
  }catch(error){$("settings-notice").textContent=error.message;}
  finally{$("api-key").value="";setBusy(false);}
}

/** Activate with the saved configuration ID and version without silently submitting unsaved form contents. */
async function activateProfile() {
  if(busy)return;
  if(dirty||!selectedProfile?.id){$("settings-notice").textContent="Save your changes before activating this configuration.";return;}
  const snapshot={...selectedProfile};$("settings-notice").textContent="";
  try{
    setBusy(true);const activated=await api(`/identity/admin/models/${snapshot.id}/activate`,{version:snapshot.version});rememberSaved(activated,true);
    try{await load(snapshot.id);$("settings-notice").textContent="Active configuration updated. New investigations will use this model.";}
    catch{$("settings-notice").textContent="Configuration activated. Status refresh failed; the active selection is retained.";}
  }
  catch(error){$("settings-notice").textContent=error.message;}
  finally{$("api-key").value="";setBusy(false);}
}

/** Read safe configuration at startup and after writes; explicitly show existing unknown-usage reservations without resetting the budget. */
async function load(preferredId) {
  const [data,health]=await Promise.all([api("/identity/model-settings"),api("/identity/health")]);catalog=data;
  $("provider").replaceChildren();for(const p of catalog.presets){const option=node("option",p.name);option.value=p.id;$("provider").append(option);}
  const active=catalog.profiles.find(p=>p.id===catalog.activeId);$("active-summary").textContent=`Active: ${active?.label||"None"} · ${active?.model||"No model configured"}`;
  $("settings-budget").textContent=`Estimate US$${Number(health.knownEstimateUsd||0).toFixed(6)} + unknown allowance US$${Number(health.unknownUsageUsd||0).toFixed(2)} / US$${Number(health.budgetUsd??3).toFixed(2)}`;
  const wasBusy=busy;busy=false;showProfile(catalog.profiles.find(p=>p.id===(preferredId||catalog.activeId))||null);busy=wasBusy;
}

$("model-form").addEventListener("submit",event=>{event.preventDefault();saveProfile();});
$("new-profile").addEventListener("click",()=>showProfile(null));
$("activate-profile").addEventListener("click",activateProfile);
$("provider").addEventListener("change",applyPreset);
for(const id of ["label","base-url","api-key","input-rate","output-rate"])$(id).addEventListener("input",markDirty);
$("model").addEventListener("input",markModelDirty);
load().catch(error=>{$("settings-notice").textContent=error.message;});
identityAdmin.init({required:true,target:"/identity/settings",notice:"settings-notice",onLogout:()=>{$("api-key").value="";}});
