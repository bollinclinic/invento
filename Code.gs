/**
 * BOLLIN CLINIC INVENTORY — Apps Script backend  · v0.2
 * ------------------------------------------------------
 * Attach this to the Bollin_Inventory_Backend Google Sheet:
 *   Extensions → Apps Script → paste this file → Deploy → New deployment
 *   → type: Web app → Execute as: Me → Who has access: Anyone → Deploy.
 * Copy the /exec URL into CONFIG.API_URL in index.html.
 *
 * Alerts: run setupTriggers() once from the editor (Run ▶) to install
 * the daily 08:00 stock check. Fill alert_email / escalation_email in
 * the Settings tab first.
 */

const ITEM_TABS = ['Consumables', 'Meds', 'Garments', 'Instruments', 'Linen'];

/* ============================ HTTP entry points ============================ */

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.ack) return ackFromEmail_(p.ack);          // one-click ack link in emails
  return json_(getAll_());
}

// action -> minimum role. Roles: common < staff < admin
const ACTION_ROLE = {
  getAll:'common', move:'common', link:'common', useLog:'common', request:'common',
  gasCheckAdd:'common',
  getTransactions:'staff',
  changePassword:'common',
  stocktake:'staff', respond:'staff', ack:'staff',
  implantAdd:'staff', implantUpdate:'staff',
  dispatchAssign:'staff', dispatchReceive:'staff', dispatchAdd:'staff', dispatchReturn:'staff',
  instrumentAdd:'staff',
  addItem:'admin', updateItem:'admin', setBarcodes:'admin',
  moveStore:'admin', storeAdd:'admin', storeRemove:'admin', clearBarcode:'admin',
  assetAdd:'admin', assetUpdate:'admin',
  useEdit:'admin', useDelete:'admin',
  setSetting:'admin', medPresetsSave:'common', instrumentDelete:'admin',
  procStart:'common', procConsume:'common', procEnd:'common', procConsumeBatch:'common',
  procSaveCart:'common', procGetCart:'common', procCancel:'common',
  procReopen:'admin', procDelete:'admin', procUpdateMeta:'admin',
  userSetRole:'admin', rotaSave:'superadmin',
  sampleSave:'staff', sampleDelete:'admin'
};
const ROLE_RANK = { common: 0, staff: 1, admin: 2, superadmin: 3 };

function doPost(e) {
  let req = {};
  try { req = JSON.parse(e.postData.contents); } catch (err) {
    return json_({ ok: false, error: 'Bad JSON' });
  }
  const lock = LockService.getScriptLock();        // serialise writes
  lock.waitLock(20000);
  try {
    if (req.action === 'login') return json_(login_(req));
    const session = auth_(req.token);
    if (!session) return json_({ ok: false, error: 'AUTH', message: 'Please sign in' });
    const need = ACTION_ROLE[req.action] || 'admin';
    if (ROLE_RANK[session.role] < ROLE_RANK[need])
      return json_({ ok: false, error: 'Your access level (' + session.role + ') cannot do this' });
    req._session = session;
    CURRENT_USER = session.name || session.u;
    switch (req.action) {
      case 'getAll':    return json_(getAll_(req._session));
      case 'getTransactions': return json_(getTransactions_(req));
      case 'changePassword': return json_(changePassword_(req));
      case 'move':      return json_(move_(req));
      case 'link':      return json_(link_(req));
      case 'addItem':   return json_(addItem_(req));
      case 'updateItem':return json_(updateItem_(req));
      case 'setBarcodes':return json_(setBarcodes_(req));
      case 'request':   return json_(addRequest_(req));
      case 'respond':   return json_(respondRequest_(req));
      case 'implantAdd':   return json_(implantAdd_(req));
      case 'implantUpdate':return json_(implantUpdate_(req));
      case 'dispatchAdd':   return json_(dispatchAdd_(req));
      case 'dispatchReturn':return json_(dispatchReturn_(req));
      case 'useLog':         return json_(useLog_(req));
      case 'dispatchAssign': return json_(dispatchAssign_(req));
      case 'dispatchReceive':return json_(dispatchReceive_(req));
      case 'instrumentAdd':  return json_(instrumentAdd_(req));
      case 'moveStore':   return json_(moveStore_(req));
      case 'storeAdd':    return json_(storeAdd_(req));
      case 'storeRemove': return json_(storeRemove_(req));
      case 'clearBarcode':return json_(clearBarcode_(req));
      case 'assetAdd':    return json_(assetAdd_(req));
      case 'assetUpdate': return json_(assetUpdate_(req));
      case 'gasCheckAdd': return json_(gasCheckAdd_(req));
      case 'useEdit':     return json_(useEdit_(req));
      case 'useDelete':   return json_(useDelete_(req));
      case 'setSetting':  return json_(setSetting_(req));
      case 'medPresetsSave': return json_(medPresetsSave_(req));
      case 'instrumentDelete': return json_(instrumentDelete_(req));
      case 'userSetRole': return json_(userSetRole_(req));
      case 'rotaSave':    return json_(rotaSave_(req));
      case 'sampleSave':   return json_(sampleSave_(req));
      case 'sampleDelete': return json_(sampleDelete_(req));
      case 'procStart':   return json_(procStart_(req));
      case 'procConsume': return json_(procConsume_(req));
      case 'procEnd':     return json_(procEnd_(req));
      case 'procConsumeBatch': return json_(procConsumeBatch_(req));
      case 'procReopen':  return json_(procReopen_(req));
      case 'procDelete':  return json_(procDelete_(req));
      case 'procCancel':  return json_(procCancel_(req));
      case 'procUpdateMeta': return json_(procUpdateMeta_(req));
      case 'procSaveCart': return json_(procSaveCart_(req));
      case 'procGetCart':  return json_(procGetCart_(req));
      case 'ack':       return json_(ackAlert_(req));
      case 'stocktake': return json_(stocktake_(req));
      default:          return json_({ ok: false, error: 'Unknown action' });
    }
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

/* ================================ helpers ================================= */

function ss_() { return SpreadsheetApp.getActiveSpreadsheet(); }

let CURRENT_USER = '';

function logAct_(activity, o) {
  // writes any event to the Transactions tab, mapped by header name
  o = o || {};
  try {
    const sh = ss_().getSheetByName('Transactions');
    const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
    const map = { Timestamp: new Date(), Direction: o.dir || '', Tracker: o.tracker || '',
      Code: o.code || '', Name: o.name || '', Qty: (o.qty === 0 || o.qty) ? o.qty : '',
      By: o.by || CURRENT_USER || '', Batch: o.batch || '', Expiry: o.expiry || '',
      Note: o.note || '', Activity: activity };
    sh.appendRow(head.map(h => map[h] !== undefined ? map[h] : ''));
  } catch (e) { /* logging must never break the action itself */ }
}

function getTransactions_(q) {
  const from = q.from ? new Date(q.from) : new Date(0);
  const to = q.to ? new Date(q.to) : new Date();
  to.setHours(23, 59, 59);
  const rows = readTab_('Transactions').filter(t => {
    const d = t.Timestamp ? new Date(t.Timestamp) : null;
    return d && d >= from && d <= to;
  });
  return { ok: true, transactions: rows.slice(0, 3000) };
}

function readTab_(name) {
  const sh = ss_().getSheetByName(name);
  if (!sh) return [];
  const vals = sh.getDataRange().getValues();
  if (vals.length < 2) return [];
  const head = vals[0].map(String);
  return vals.slice(1)
    .map((row, i) => {
      const o = { _row: i + 2 };                    // sheet row number
      head.forEach((h, c) => o[h] = row[c] === '' ? null : row[c]);
      return o;
    })
    .filter(o => Object.keys(o).some(k => k !== '_row' && o[k] !== null && o[k] !== undefined));
}

function findItem_(tracker, code) {
  const sh = ss_().getSheetByName(tracker);
  if (!sh) throw 'No tab: ' + tracker;
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'), cName = head.indexOf('Name');
  const target = String(code == null ? '' : code).trim();
  if (!target) throw 'No identifier given';
  let byName = null;
  for (let r = 1; r < vals.length; r++) {
    const vc = String(vals[r][cCode] == null ? '' : vals[r][cCode]).trim();
    const vb = cBar >= 0 ? String(vals[r][cBar] == null ? '' : vals[r][cBar]).trim() : '';
    if ((vc && vc === target) || (vb && vb === target)) {
      return { sh: sh, row: r + 1, head: head, vals: vals[r] };
    }
    if (cName >= 0 && !byName) {
      const vn = String(vals[r][cName] == null ? '' : vals[r][cName]).trim();
      if (vn && vn === target) byName = { sh: sh, row: r + 1, head: head, vals: vals[r] };
    }
  }
  if (byName) return byName;                       // fallback: exact name match
  throw 'Item not found: ' + code + ' in ' + tracker;
}

function addItem_(q) {
  // q: {tracker, fields:{Code,Barcode,Name,...}} — mapped by header name
  const sh = ss_().getSheetByName(q.tracker);
  if (!sh) return { ok: false, error: 'No tab: ' + q.tracker };
  if (!q.fields || !q.fields.Name) return { ok: false, error: 'Name required' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);

  // ---- guard against accidental duplicates ----
  // If a row already exists with the same non-blank Code, or same non-blank Barcode, or
  // (when this item has no code/barcode) the same Name, treat this as an UPDATE of that row
  // instead of appending a second copy. This makes duplicates impossible even if the client
  // mistakenly calls addItem for an item that already exists.
  {
    const all = sh.getDataRange().getValues();
    const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'), cName = head.indexOf('Name');
    const nc = String(q.fields.Code || '').trim();
    const nb = String(q.fields.Barcode || '').trim();
    const nn = String(q.fields.Name || '').trim().toLowerCase();
    for (let r = 1; r < all.length; r++) {
      const vc = cCode >= 0 ? String(all[r][cCode] || '').trim() : '';
      const vb = cBar >= 0 ? String(all[r][cBar] || '').trim() : '';
      const vn = cName >= 0 ? String(all[r][cName] || '').trim().toLowerCase() : '';
      const hit = (nc && vc && nc === vc) || (nb && vb && nb === vb) ||
                  (!nc && !nb && nn && vn === nn);
      if (hit) {
        // update that existing row instead of adding a duplicate
        return updateItem_({ tracker: q.tracker, row: r + 1, fields: q.fields,
          _origCode: vc, _origBar: vb, _origName: all[r][cName] });
      }
    }
  }

  const row = head.map(h => {
    let v = q.fields[h];
    if (v === undefined || v === null) return '';
    if (h === 'Expiry' && v) return new Date(v);
    return v;
  });
  sh.appendRow(row);
  if (q.fields.Barcode) {
    ss_().getSheetByName('BarcodeLinks')
      .appendRow([q.fields.Barcode, q.tracker, q.fields.Code || q.fields.Name]);
  }
  logAct_('Item added', {tracker: q.tracker, code: q.fields.Code || '', name: q.fields.Name,
    qty: q.fields.Qty, note: 'New item created'});
  return { ok: true, row: sh.getLastRow() };
}

function setBarcodes_(q) {
  // q: {entries:[{tracker, code, barcode}]} — batch assign generated codes
  const links = ss_().getSheetByName('BarcodeLinks');
  let done = 0, errors = [];
  (q.entries || []).forEach(en => {
    try {
      const it = findItem_(en.tracker, en.code);
      it.sh.getRange(it.row, col_(it.head, 'Barcode')).setValue(en.barcode);
      links.appendRow([en.barcode, en.tracker, en.code]);
      done++;
    } catch (err) { errors.push(en.code + ': ' + err); }
  });
  logAct_('Barcodes generated', {tracker: (q.entries && q.entries[0] && q.entries[0].tracker) || '',
    qty: done, note: done + ' barcode label(s) assigned'});
  return { ok: true, done: done, errors: errors.slice(0, 10) };
}

function itemAtRow_(tracker, row) {
  const sh = ss_().getSheetByName(tracker);
  if (!sh) throw 'No tab: ' + tracker;
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const vals = sh.getRange(row, 1, 1, sh.getLastColumn()).getValues()[0];
  return { sh: sh, row: row, head: head, vals: vals };
}

function col_(head, name) {
  const i = head.indexOf(name);
  if (i < 0) throw 'Missing column ' + name;
  return i + 1;
}

function setSetting_(q) {
  // q: {key, value} — upsert a Settings row (used for saved sticker margins etc.)
  const sh = ss_().getSheetByName('Settings');
  if (!sh) return { ok: false, error: 'Settings tab missing' };
  const vals = sh.getRange(1, 1, Math.max(sh.getLastRow(), 1), 1).getValues().map(r => String(r[0]));
  const at = vals.indexOf(String(q.key));
  if (at >= 0) sh.getRange(at + 1, 2).setValue(q.value);
  else sh.appendRow([q.key, q.value, 'Saved from the app']);
  return { ok: true };
}

const ROTA_THEATRE_FIELDS = ['Type','Detail','Colour','CasesJSON','Surgeon','Surgeon2','Surgeon3',
  'Anaesthetist','SFA','Scrub1','Scrub2','Scrub3','ODP'];
const ROTA_DAY_FIELDS = ['HCAWard','HCATheatre','WardNurse','NightNurse','RecoveryNurse',
  'RMODay','RMONight','HousekeepingAM','HousekeepingPM','ReceptionAM','ReceptionPM','Notes','AcksJSON','StarsJSON'];
const ROTA_HEADERS = ['Date','Theatres'].concat(ROTA_DAY_FIELDS)
  .concat(ROTA_THEATRE_FIELDS.map(f=>'T1_'+f))
  .concat(ROTA_THEATRE_FIELDS.map(f=>'T2_'+f));

function userSetRole_(q) {
  // admin / superadmin: change a user's role — used to appoint the super admins
  const ok = ['common', 'staff', 'admin', 'superadmin'];
  if (ok.indexOf(String(q.role)) < 0) return { ok: false, error: 'Unknown role' };
  const sh = ss_().getSheetByName('Users');
  if (!sh) return { ok: false, error: 'Users tab missing' };
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const cU = head.indexOf('Username'), cR = head.indexOf('Role');
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][cU]).toLowerCase() === String(q.username || '').toLowerCase()) {
      const old = String(vals[r][cR] || '');
      sh.getRange(r + 1, cR + 1).setValue(q.role);
      logAct_('User role changed', { tracker: 'Users', code: String(vals[r][cU]),
        name: String(vals[r][cU]), by: q.by, note: old + ' → ' + q.role });
      return { ok: true };
    }
  }
  return { ok: false, error: 'User not found' };
}

function rotaSave_(q) {
  // superadmin: upsert one day of the theatre rota, keyed by Date (stored as plain text
  // to avoid timezone shifts on read-back)
  const sh = ss_().getSheetByName('Rota');
  if (!sh) return { ok: false, error: 'Rota tab missing — run migrate()' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const dateStr = String(q.date || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) return { ok: false, error: 'Bad date' };
  const f = q.fields || {};
  f.Date = dateStr;
  const vals = sh.getDataRange().getValues();
  const cD = head.indexOf('Date');
  let row = 0;
  for (let r = 1; r < vals.length; r++)
    if (String(vals[r][cD]).slice(0, 10) === dateStr) { row = r + 1; break; }
  const out = head.map(function (hn) { return f[hn] !== undefined ? f[hn] : ''; });
  if (row) {
    const cur = sh.getRange(row, 1, 1, head.length).getValues()[0];
    head.forEach(function (hn, i) { if (f[hn] === undefined) out[i] = cur[i]; });
    sh.getRange(row, 1, 1, head.length).setValues([out]);
  } else {
    sh.appendRow(out);
    row = sh.getLastRow();
  }
  sh.getRange(row, cD + 1).setNumberFormat('@').setValue(dateStr);
  logAct_('Rota updated', { tracker: 'Rota', code: dateStr, name: 'Theatre rota', by: q.by,
    note: (Number(f.Theatres) || 0) + ' theatre(s)' });
  return { ok: true };
}

function sampleSave_(q) {
  // upsert a specimen row keyed by SampleID (one row per specimen; a patient can have several)
  const sh = ss_().getSheetByName('Samples');
  if (!sh) return { ok: false, error: 'Samples tab missing — run migrate()' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  let id = String(q.sampleId || '').trim();
  const f = q.fields || {};
  const vals = sh.getDataRange().getValues();
  const cID = head.indexOf('SampleID');
  let row = 0;
  if (id) for (let r = 1; r < vals.length; r++) if (String(vals[r][cID]) === id) { row = r + 1; break; }
  if (!id) { id = 'SMP-' + Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyyMMdd-HHmmss') + '-' + Math.floor(Math.random() * 1000); }
  f.SampleID = id;
  const out = head.map(function (hn) { return f[hn] !== undefined ? f[hn] : ''; });
  if (row) {
    const cur = sh.getRange(row, 1, 1, head.length).getValues()[0];
    head.forEach(function (hn, i) { if (f[hn] === undefined) out[i] = cur[i]; });
    sh.getRange(row, 1, 1, head.length).setValues([out]);
  } else {
    sh.appendRow(out); row = sh.getLastRow();
  }
  const cD = head.indexOf('Date');
  if (cD >= 0) sh.getRange(row, cD + 1).setNumberFormat('@');
  logAct_('Sample logged', { tracker: 'Samples', code: id,
    name: (f.PATNumber || '') + ' · ' + (f.SampleDetails || ''), by: q.by,
    note: (f.Category || '') });
  return { ok: true, sampleId: id };
}

function sampleDelete_(q) {
  const sh = ss_().getSheetByName('Samples');
  if (!sh) return { ok: false, error: 'Samples tab missing' };
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const cID = head.indexOf('SampleID');
  const id = String(q.sampleId || '').trim();
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][cID]) === id) {
      sh.deleteRow(r + 1);
      logAct_('Sample deleted', { tracker: 'Samples', code: id, name: id, by: q.by, note: 'Removed' });
      return { ok: true };
    }
  }
  return { ok: false, error: 'Sample not found' };
}

function instrumentDelete_(q) {
  // admin: remove an Instruments row that was added by mistake.
  // The row's identity (Code / Barcode / Name) is verified before deletion so the
  // wrong row can never be removed, even if the supplied row number is stale.
  const sh = ss_().getSheetByName('Instruments');
  if (!sh) return { ok: false, error: 'Instruments tab missing' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'), cName = head.indexOf('Name');
  const last = sh.getLastRow();
  const oc = String(q._origCode || '').trim(), ob = String(q._origBar || '').trim(),
        on = String(q._origName || '').trim().toLowerCase();
  function idAt(r) {
    const v = sh.getRange(r, 1, 1, head.length).getValues()[0];
    return { code: cCode >= 0 ? String(v[cCode] || '').trim() : '',
             bar:  cBar  >= 0 ? String(v[cBar]  || '').trim() : '',
             name: cName >= 0 ? String(v[cName] || '').trim().toLowerCase() : '' };
  }
  function matches(id) {
    if (oc && id.code && id.code === oc) return true;
    if (ob && id.bar && id.bar === ob) return true;
    if (!oc && !ob && on && id.name === on) return true;
    return false;
  }
  let row = 0;
  const supplied = Number(q.row) || 0;
  if (supplied >= 2 && supplied <= last && matches(idAt(supplied))) row = supplied;
  else for (let r = 2; r <= last; r++) if (matches(idAt(r))) { row = r; break; }
  if (!row) return { ok: false, error: 'Could not locate the instrument to delete — refresh and try again' };
  const nm = cName >= 0 ? sh.getRange(row, cName + 1).getValue() : '';
  sh.deleteRow(row);
  logAct_('Instrument deleted', { tracker: 'Instruments', code: oc || ob,
    name: String(nm || q._origName || ''), by: q.by,
    note: 'Removed from on-hand register (added by mistake)' });
  return { ok: true };
}

function medPresetsSave_(q) {
  // saved medication-label presets (shared, any role — clinical convenience list)
  const sh = ss_().getSheetByName('Settings');
  if (!sh) return { ok: false, error: 'Settings tab missing' };
  const vals = sh.getRange(1, 1, Math.max(sh.getLastRow(), 1), 1).getValues().map(r => String(r[0]));
  const at = vals.indexOf('med_sticker_presets');
  if (at >= 0) sh.getRange(at + 1, 2).setValue(q.json || '[]');
  else sh.appendRow(['med_sticker_presets', q.json || '[]', 'Saved from the app']);
  return { ok: true };
}

function setting_(key, fallback) {
  const row = readTab_('Settings').find(r => r.Key === key);
  return row && row.Value != null && row.Value !== '' ? row.Value : fallback;
}

/* ================================ actions ================================= */

function getAll_(session) {
  const items = {};
  const hideCost = session && session.role === 'common';
  ITEM_TABS.forEach(t => {
    items[t] = readTab_(t);
    if (hideCost) items[t].forEach(r => { delete r.UnitCost; });
  });
  const tx = readTab_('Transactions');
  return {
    ok: true,
    role: session ? session.role : 'admin',
    displayName: session ? session.name : '',
    items: items,
    transactions: tx.slice(-200).reverse(),
    requests: readTab_('Requests').reverse(),
    alerts: readTab_('Alerts').slice(-100).reverse(),
    implants: readTab_('Implants').reverse(),
    dispatch: readTab_('DispatchLog').reverse(),
    barcodeLinks: readTab_('BarcodeLinks'),
    stores: readTab_('Stores'),
    assets: (session && session.role === 'admin') ? readTab_('Assets') : [],
    gasChecks: readTab_('GasChecks').slice(-180),
    settings: readTab_('Settings'),
    procedures: procForRole_(session),
    procLines: (session && ROLE_RANK[session.role] >= 2) ? readTab_('ProcedureLines').slice(-500) : [],
    users: (session && ROLE_RANK[session.role] >= 2) ? readTab_('Users').map(function (u) {
      return { Username: u.Username, DisplayName: u.DisplayName, Role: u.Role, Active: u.Active };
    }) : [],
    rota: (session && session.role === 'superadmin') ? readTab_('Rota') : [],
    samples: (session && ROLE_RANK[session.role] >= 1) ? readTab_('Samples') : [],
    serverTime: new Date().toISOString()
  };
}

function move_(q) {
  // q: {tracker, code, row?, dir:'in'|'out', qty, by, batch, expiry, note}
  const it = q.row ? itemAtRow_(q.tracker, Number(q.row)) : findItem_(q.tracker, q.code);
  const qty = Math.max(1, Number(q.qty) || 1);
  let newQty = null;

  if (q.tracker === 'Instruments') {
    const c = col_(it.head, 'Status');
    it.sh.getRange(it.row, c).setValue(q.dir === 'out' ? 'At Countess' : 'At Bollin');
    if (q.dir === 'in') {                          // a return = one sterilisation cycle
      const cc = it.head.indexOf('CyclesToDate');
      if (cc >= 0) {
        const cur = Number(it.vals[cc]) || 0;
        it.sh.getRange(it.row, cc + 1).setValue(cur + 1);
      }
    }
  } else {
    const cQty = col_(it.head, 'Qty');
    const cur = Number(it.vals[cQty - 1]) || 0;
    newQty = q.dir === 'in' ? cur + qty : cur - qty;
    if (newQty < 0) return { ok: false, error: 'Only ' + cur + ' in stock' };
    it.sh.getRange(it.row, cQty).setValue(newQty);
    if (q.dir === 'in') {
      if (q.batch)  it.sh.getRange(it.row, col_(it.head, 'Batch')).setValue(q.batch);
      if (q.expiry && it.head.indexOf('Expiry') >= 0)
        it.sh.getRange(it.row, col_(it.head, 'Expiry')).setValue(new Date(q.expiry));
    }
  }

  const name = it.vals[it.head.indexOf('Name')];
  logAct_(q.dir === 'in' ? 'Stock in' : 'Stock out', {dir: q.dir, tracker: q.tracker,
    code: q.code, name: name, qty: qty, by: q.by, batch: q.batch, expiry: q.expiry, note: q.note});
  return { ok: true, newQty: newQty, name: name };
}

function link_(q) {
  // q: {barcode, tracker, code}
  ss_().getSheetByName('BarcodeLinks').appendRow([q.barcode, q.tracker, q.code]);
  const it = findItem_(q.tracker, q.code);
  const cBar = col_(it.head, 'Barcode');
  if (!it.vals[cBar - 1]) it.sh.getRange(it.row, cBar).setValue(q.barcode);
  logAct_('Barcode linked', {tracker: q.tracker, code: q.code,
    name: String(it.vals[col_(it.head, 'Name') - 1] || ''), note: 'Scanned barcode ' + q.barcode + ' linked'});
  return { ok: true };
}

function addRequest_(q) {
  // Requests schema: Timestamp | By | Item | Qty | Size | Status | HandledBy | DateResponded | Remarks
  ss_().getSheetByName('Requests').appendRow([
    new Date(), q.by || 'Unknown', q.item,
    Math.max(1, Number(q.qty) || 1), q.size || '', 'Requested', '', '', ''
  ]);
  logAct_('Request submitted', {tracker: 'Requests', name: q.item, qty: q.qty, by: q.by, note: q.size ? 'Size: ' + q.size : ''});
  const notify = setting_('request_email', '');
  if (notify) {
    try {
      MailApp.sendEmail({ to: notify,
        subject: setting_('app_name', 'Bollin Clinic Inventory') + ' — new request: ' + q.item,
        htmlBody: '<p><b>' + (q.by || 'Someone') + '</b> has requested:</p>' +
          '<p style="font-size:15px"><b>' + q.item + '</b> — qty ' + (q.qty || 1) +
          (q.size ? ', size ' + q.size : '') + '</p>' +
          '<p>Respond in the app under Requests.</p>' });
    } catch (e) { /* email failure must not block the request */ }
  }
  return { ok: true };
}

function respondRequest_(q) {
  // q: {row, status, by, remarks}
  const sh = ss_().getSheetByName('Requests');
  sh.getRange(q.row, 6).setValue(q.status);
  sh.getRange(q.row, 7).setValue(q.by || '');
  sh.getRange(q.row, 8).setValue(new Date());
  sh.getRange(q.row, 9).setValue(q.remarks || '');
  logAct_('Request answered', {tracker: 'Requests',
    name: String(sh.getRange(q.row, 3).getValue() || ''), by: q.by,
    note: 'Status: ' + q.status + (q.remarks ? ' — ' + q.remarks : '')});
  return { ok: true };
}

function updateItem_(q) {
  // q: {tracker, row, fields:{header:value,...}} — updates one item row in place.
  // Row resolution priority (so an edit can NEVER duplicate, even for meds with blank codes):
  //   1. If q.row is in range AND the row's current identity matches what we're editing
  //      (by Code, or Barcode, or original Name), trust it. This is the normal path.
  //   2. Otherwise re-find by original Code, then original Barcode, then original Name.
  //   3. If still nothing, ERROR (never append — appending is what caused duplicates).
  const sh = ss_().getSheetByName(q.tracker);
  if (!sh) return { ok: false, error: 'No tab: ' + q.tracker };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'), cName = head.indexOf('Name');
  const last = sh.getLastRow();

  const oc = String((q._origCode != null ? q._origCode : (q.fields && q.fields.Code)) || '').trim();
  const ob = String((q._origBar != null ? q._origBar : (q.fields && q.fields.Barcode)) || '').trim();
  const on = String((q._origName != null ? q._origName : (q.fields && q.fields.Name)) || '').trim().toLowerCase();

  function idAt(r) {
    const vals = sh.getRange(r, 1, 1, head.length).getValues()[0];
    return {
      code: cCode >= 0 ? String(vals[cCode] || '').trim() : '',
      bar:  cBar  >= 0 ? String(vals[cBar]  || '').trim() : '',
      name: cName >= 0 ? String(vals[cName] || '').trim().toLowerCase() : ''
    };
  }
  function matches(id) {
    if (oc && id.code && id.code === oc) return true;
    if (ob && id.bar && id.bar === ob) return true;
    // name match only when there is no code/barcode to disambiguate (typical for meds)
    if (!oc && !ob && on && id.name === on) return true;
    return false;
  }

  let row = 0;
  const supplied = Number(q.row) || 0;
  if (supplied >= 2 && supplied <= last && matches(idAt(supplied))) {
    row = supplied;                                  // priority 1: supplied row is correct
  } else {
    for (let r = 2; r <= last; r++) {                // priority 2: re-find
      if (matches(idAt(r))) { row = r; break; }
    }
    // last resort: if we have a plain name and a valid supplied row whose name equals it, use it
    if (!row && supplied >= 2 && supplied <= last && on && idAt(supplied).name === on) row = supplied;
  }
  if (!row) return { ok: false, error: 'Could not locate the item to update — please refresh and try again' };
  q.row = row;

  // build a human-readable change note by comparing old vs new
  const LABEL = { UnitCost: 'price', Qty: 'quantity', ReorderLevel: 'reorder level',
    Location: 'location', Category: 'category', Supplier: 'supplier', Expiry: 'expiry',
    Name: 'name', Barcode: 'barcode', Unit: 'unit', Batch: 'batch', Notes: 'remarks',
    Obsolete: 'obsolete flag', Status: 'status' };
  const oldRow = sh.getRange(q.row, 1, 1, head.length).getValues()[0];
  const changes = [];
  Object.keys(q.fields || {}).forEach(h => {
    const ci = head.indexOf(h); if (ci < 0) return;
    let ov = oldRow[ci], nv = q.fields[h];
    const os = ov === null || ov === undefined ? '' : String(ov).slice(0, 30);
    const ns = nv === null || nv === undefined ? '' : String(nv).slice(0, 30);
    if (os === ns) return;
    const lab = LABEL[h] || h;
    if (h === 'UnitCost') changes.push(os === '' ? 'price set to £' + ns : 'price £' + os + ' → £' + ns);
    else if (h === 'Qty') changes.push('quantity ' + (os || 0) + ' → ' + (ns || 0));
    else if (os === '') changes.push(lab + ' set to "' + ns + '"');
    else if (ns === '') changes.push(lab + ' cleared');
    else changes.push(lab + ' "' + os + '" → "' + ns + '"');
  });
  q._changeNote = changes.length ? changes.join('; ') : 'Item details updated';

  // stamp obsolete metadata when the Obsolete flag is being set/cleared
  if (q.fields && Object.prototype.hasOwnProperty.call(q.fields, 'Obsolete')) {
    const cWho = head.indexOf('ObsoleteBy'), cWhen = head.indexOf('ObsoleteAt');
    const on = String(q.fields.Obsolete || '').toLowerCase() === 'yes';
    if (cWho >= 0) sh.getRange(q.row, cWho + 1).setValue(on ? (CURRENT_USER || '') : '');
    if (cWhen >= 0) sh.getRange(q.row, cWhen + 1).setValue(on ? new Date() : '');
  }

  Object.keys(q.fields || {}).forEach(h => {
    const c = head.indexOf(h);
    if (c < 0) return;
    let v = q.fields[h];
    if (v === null || v === undefined) v = '';
    if (h === 'Expiry' && v) v = new Date(v);
    sh.getRange(q.row, c + 1).setValue(v);
  });
  logAct_('Item edited', {tracker: q.tracker, code: (q.fields && q.fields.Code) || '',
    name: (q.fields && q.fields.Name) || '', note: q._changeNote || 'Item details updated'});
  return { ok: true };
}

/* ============================== implants ================================= */

const IMPLANT_HEADERS = ['Timestamp','PatientInitials','PATNumber','Surgeon','SurgeryDate',
  'ImplantDetails','Qty','Remarks','DateOrdered','OrderedBy','Status','ReceivedBy','ReceivedDate',
  'ReceivedQty','StorageLocation','ScannedRef','ReturnDetails','ReturnedQty','ReturnedBy','ReturnedDate','Notes'];

function implantAdd_(q) {
  const sh = ss_().getSheetByName('Implants');
  if (!sh) return { ok: false, error: 'Implants tab missing — run migrate() in the script editor' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const f = q.fields || {};
  f.Timestamp = new Date();
  const row = head.map(h => {
    let v = f[h];
    if (v === undefined || v === null) return '';
    if (h.indexOf('Date') >= 0 && v) return new Date(v);
    return v;
  });
  sh.appendRow(row);
  logAct_('Implant ordered', {tracker: 'Implants', code: f.PATNumber || '',
    name: (f.PatientInitials || '') + ' — ' + (f.ImplantDetails || ''), qty: f.Qty,
    note: 'Status: ' + (f.Status || 'Pending')});
  const notify = setting_('implant_email', '');
  if (notify) {
    try {
      MailApp.sendEmail({ to: notify,
        subject: setting_('app_name', 'Bollin Clinic Inventory') + ' — new implant order: ' +
          (f.PatientInitials || '') + ' (' + (f.PATNumber || '') + ')',
        htmlBody: '<p>A new implant order has been created:</p><table style="border-collapse:collapse">' +
          [['Patient', f.PatientInitials], ['PAT number', f.PATNumber], ['Surgeon', f.Surgeon],
           ['Surgery date', f.SurgeryDate], ['Implants', f.ImplantDetails], ['Qty', f.Qty],
           ['Ordered by', f.OrderedBy], ['Status', f.Status || 'Pending'], ['Remarks', f.Remarks]]
          .filter(x => x[1]).map(x =>
            '<tr><td style="border:1px solid #C9D6D2;padding:4px 8px;background:#F2F7F6;font-weight:600">' +
            x[0] + '</td><td style="border:1px solid #C9D6D2;padding:4px 8px">' + x[1] + '</td></tr>').join('') +
          '</table><p>Track it in the app under Implant orders.</p>' });
    } catch (e) { /* never block the order */ }
  }
  return { ok: true, row: sh.getLastRow() };
}

function implantUpdate_(q) {
  // q: {row, fields:{Status, ReceivedBy, ReceivedDate, ScannedRef, ReturnDetails, ReturnedBy, ReturnedDate,...}}
  const sh = ss_().getSheetByName('Implants');
  if (!sh) return { ok: false, error: 'Implants tab missing — run migrate()' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  Object.keys(q.fields || {}).forEach(h => {
    const c = head.indexOf(h);
    if (c < 0) return;
    let v = q.fields[h];
    if (v === null || v === undefined) v = '';
    if ((h.indexOf('Date') >= 0) && v) v = new Date(v);
    sh.getRange(q.row, c + 1).setValue(v);
  });
  const pat = sh.getRange(q.row, head.indexOf('PATNumber') + 1).getValue();
  const ini = sh.getRange(q.row, head.indexOf('PatientInitials') + 1).getValue();
  logAct_('Implant updated', {tracker: 'Implants', code: String(pat || ''),
    name: String(ini || ''), note: Object.keys(q.fields || {}).map(k => k + ': ' + q.fields[k]).join(', ').slice(0, 180)});
  return { ok: true };
}

/* ============================ dispatch log =============================== */

const DISPATCH_HEADERS = ['DispatchRef','DateSent','SentBy','ItemName','Code','CountOut',
  'BatchLot','Instructions','CollectedBy','DateCollected','CountessRef',
  'DateReturned','ReturnedBy','CountIn','Status','DateUsed','UsedBy'];

function dlSheet_() {
  const sh = ss_().getSheetByName('DispatchLog');
  if (!sh) throw 'DispatchLog tab missing — run migrate()';
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  return { sh: sh, head: head, col: n => head.indexOf(n) + 1 };
}

function useLog_(q) {
  // q: {by, date, lines:[{code, name, qty}]} -> rows with Status 'Pending Collection'
  const d = dlSheet_();
  const rows = (q.lines || []).map(l => {
    const r = new Array(d.head.length).fill('');
    r[d.col('ItemName') - 1] = l.name || '';
    r[d.col('Code') - 1] = l.code || '';
    r[d.col('CountOut') - 1] = Math.max(1, Number(l.qty) || 1);
    r[d.col('Status') - 1] = 'Pending Collection';
    r[d.col('DateUsed') - 1] = q.date ? new Date(q.date) : new Date();
    r[d.col('UsedBy') - 1] = q.by || '';
    return r;
  });
  if (!rows.length) return { ok: false, error: 'No lines' };
  d.sh.getRange(d.sh.getLastRow() + 1, 1, rows.length, d.head.length).setValues(rows);
  (q.lines || []).forEach(l => logAct_('Instrument used', {tracker: 'Sterilisation',
    code: l.code, name: l.name, qty: l.qty, by: q.by}));
  return { ok: true, added: rows.length };
}

function useEdit_(q) {
  // q: {row, name, code, qty} — only allowed while still Pending Collection
  const d = dlSheet_();
  const st = String(d.sh.getRange(q.row, d.col('Status')).getValue() || '');
  if (st !== 'Pending Collection')
    return { ok: false, error: 'This item has already been dispatched and can no longer be edited' };
  if (q.name !== undefined) d.sh.getRange(q.row, d.col('ItemName')).setValue(q.name);
  if (q.code !== undefined) d.sh.getRange(q.row, d.col('Code')).setValue(q.code);
  if (q.qty !== undefined) d.sh.getRange(q.row, d.col('CountOut')).setValue(Math.max(1, Number(q.qty) || 1));
  logAct_('Used item edited', {tracker: 'Sterilisation', code: q.code || '', name: q.name || '',
    qty: q.qty, note: 'Corrected before dispatch'});
  return { ok: true };
}

function useDelete_(q) {
  // q: {row} — only allowed while still Pending Collection
  const d = dlSheet_();
  const st = String(d.sh.getRange(q.row, d.col('Status')).getValue() || '');
  if (st !== 'Pending Collection')
    return { ok: false, error: 'This item has already been dispatched and cannot be removed here' };
  const nm = d.sh.getRange(q.row, d.col('ItemName')).getValue();
  d.sh.deleteRow(q.row);
  logAct_('Used item removed', {tracker: 'Sterilisation', name: String(nm || ''),
    note: 'Removed before dispatch'});
  return { ok: true };
}

function dispatchAssign_(q) {
  // q: {rows:[sheetRow,...], ref, date, by, batch, instructions}
  const d = dlSheet_();
  (q.rows || []).forEach(r => {
    d.sh.getRange(r, d.col('DispatchRef')).setValue(q.ref || '');
    d.sh.getRange(r, d.col('DateSent')).setValue(q.date ? new Date(q.date) : new Date());
    d.sh.getRange(r, d.col('SentBy')).setValue(q.by || '');
    if (q.batch) d.sh.getRange(r, d.col('BatchLot')).setValue(q.batch);
    if (q.instructions) d.sh.getRange(r, d.col('Instructions')).setValue(q.instructions);
    d.sh.getRange(r, d.col('Status')).setValue('Out');
  });
  dispatchAssign_Register_(q.rows || []);
  logAct_('Instruments dispatched', {tracker: 'Sterilisation', code: q.ref,
    name: 'Dispatch ' + (q.ref || ''), qty: (q.rows || []).length, by: q.by,
    note: (q.rows || []).length + ' line(s) sent to CSSD'});
  return { ok: true, dispatched: (q.rows || []).length };
}

function dispatchReceive_(q) {
  // q: {rows:[sheetRow,...], by}
  // On receive: expiry = dispatch (sterilisation) date + 1 year, written to the
  // Instruments register. Unknown codes are added to the register automatically.
  const d = dlSheet_();
  (q.rows || []).forEach(r => {
    const out = Number(d.sh.getRange(r, d.col('CountOut')).getValue()) || 0;
    const sent = d.sh.getRange(r, d.col('DateSent')).getValue();
    const code = String(d.sh.getRange(r, d.col('Code')).getValue() || '').trim();
    const name = String(d.sh.getRange(r, d.col('ItemName')).getValue() || '').trim();
    d.sh.getRange(r, d.col('DateReturned')).setValue(new Date());
    d.sh.getRange(r, d.col('ReturnedBy')).setValue(q.by || '');
    d.sh.getRange(r, d.col('CountIn')).setValue(out);
    d.sh.getRange(r, d.col('Status')).setValue('Returned');
    if (code) {
      const base = (sent && sent instanceof Date) ? new Date(sent) : new Date();
      const expiry = new Date(base); expiry.setFullYear(expiry.getFullYear() + 1);
      upsertInstrument_(code, name, { Expiry: expiry, Status: 'At Bollin' });
    }
  });
  logAct_('Instruments received', {tracker: 'Sterilisation',
    name: 'CSSD return', qty: (q.rows || []).length, by: q.by,
    note: (q.rows || []).length + ' line(s) received back'});
  return { ok: true, received: (q.rows || []).length };
}

function dispatchAssign_Register_(rows) {
  // mark register items as out when dispatched
  const d = dlSheet_();
  rows.forEach(r => {
    const code = String(d.sh.getRange(r, d.col('Code')).getValue() || '').trim();
    if (code) { try { upsertInstrument_(code, '', { Status: 'At CSSD' }); } catch (e) {} }
  });
}

function upsertInstrument_(code, name, fields) {
  const sh = ss_().getSheetByName('Instruments');
  if (!sh) return;
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode');
  let row = -1;
  for (let r = 1; r < vals.length; r++) {
    const vc = String(vals[r][cCode] || '').trim();
    const vb = cBar >= 0 ? String(vals[r][cBar] || '').trim() : '';
    if ((vc && vc === code) || (vb && vb === code)) { row = r + 1; break; }
  }
  if (row < 0) {                                   // auto-register a new instrument
    const newRow = head.map(h =>
      h === 'Code' ? code : h === 'Barcode' ? code :
      h === 'Name' ? (name || code) :
      h === 'Category' ? (String(name).toLowerCase().indexOf('tray') >= 0 ? 'Tray' : 'Instrument') : '');
    sh.appendRow(newRow);
    row = sh.getLastRow();
  }
  Object.keys(fields || {}).forEach(h => {
    const c2 = head.indexOf(h);
    if (c2 >= 0) sh.getRange(row, c2 + 1).setValue(fields[h]);
  });
}

function instrumentAdd_(q) {
  // q: {fields:{Code, Barcode, Name, Category, Description, QtyInTray, Expiry, Notes, Status}}
  const sh = ss_().getSheetByName('Instruments');
  if (!sh) return { ok: false, error: 'Instruments tab missing' };
  const f = q.fields || {};
  if (!f.Name) return { ok: false, error: 'Name required' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const row = head.map(h => {
    let v = f[h];
    if (v === undefined || v === null) return '';
    if (h === 'Expiry' && v) return new Date(v);
    return v;
  });
  sh.appendRow(row);
  if (f.Barcode) ss_().getSheetByName('BarcodeLinks')
    .appendRow([f.Barcode, 'Instruments', f.Code || f.Name]);
  logAct_('Instrument registered', {tracker: 'Sterilisation', code: f.Code,
    name: f.Name, qty: f.QtyInTray});
  return { ok: true, row: sh.getLastRow() };
}

function dispatchAdd_(q) {
  // q: {ref, date, by, batch, lines:[{code, name, qtyOut, instructions}]}
  const sh = ss_().getSheetByName('DispatchLog');
  if (!sh) return { ok: false, error: 'DispatchLog tab missing — run migrate()' };
  const rows = (q.lines || []).map(l => [
    q.ref || '', q.date ? new Date(q.date) : new Date(), q.by || '',
    l.name || '', l.code || '', Math.max(1, Number(l.qtyOut) || 1),
    q.batch || '', l.instructions || '', '', '', '', '', '', '', 'Out'
  ]);
  if (!rows.length) return { ok: false, error: 'No lines' };
  sh.getRange(sh.getLastRow() + 1, 1, rows.length, DISPATCH_HEADERS.length).setValues(rows);
  logAct_('Instruments dispatched', {tracker: 'Sterilisation', code: q.ref || '',
    name: 'Dispatch ' + (q.ref || ''), qty: rows.length, by: q.by,
    note: rows.length + ' line(s) sent to CSSD'});
  return { ok: true, added: rows.length };
}

function dispatchReturn_(q) {
  // q: {row, qtyIn, by}
  const sh = ss_().getSheetByName('DispatchLog');
  if (!sh) return { ok: false, error: 'DispatchLog tab missing — run migrate()' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const get = n => head.indexOf(n) + 1;
  const qtyOut = Number(sh.getRange(q.row, get('CountOut')).getValue()) || 0;
  const qtyIn = Number(q.qtyIn) || qtyOut;
  sh.getRange(q.row, get('DateReturned')).setValue(new Date());
  sh.getRange(q.row, get('ReturnedBy')).setValue(q.by || '');
  sh.getRange(q.row, get('CountIn')).setValue(qtyIn);
  sh.getRange(q.row, get('Status')).setValue(qtyIn >= qtyOut ? 'Returned' : 'Partial');
  logAct_('Instruments received', {tracker: 'Sterilisation',
    name: String(sh.getRange(q.row, get('ItemName')).getValue() || ''),
    code: String(sh.getRange(q.row, get('Code')).getValue() || ''),
    qty: qtyIn, by: q.by, note: qtyIn >= qtyOut ? 'Fully returned' : 'Partial return'});
  return { ok: true };
}

/* ============================== migration ================================ */
/** Run once from the editor after pasting this version (Run ▶ migrate). */
function migrate() {
  const ss = ss_();

  // 0. Core tabs — create any that don't exist yet (fresh/blank sheet, e.g. staging).
  //    All guarded by "if missing", so this is a no-op on an established sheet.
  const HEAD_STYLE = r => r.setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
  function ensureTab_(name, headers, seedRows) {
    let s = ss.getSheetByName(name);
    if (!s) {
      s = ss.insertSheet(name);
      HEAD_STYLE(s.getRange(1, 1, 1, headers.length).setValues([headers]));
      s.setFrozenRows(1);
      if (seedRows && seedRows.length)
        s.getRange(2, 1, seedRows.length, headers.length).setValues(seedRows);
    }
    return s;
  }
  const ITEM_HEADERS = ['Code', 'Barcode', 'Name', 'Category', 'Supplier', 'Location',
    'Unit', 'Qty', 'ReorderLevel', 'UnitCost', 'Expiry', 'Batch', 'Notes', 'Status',
    'Obsolete', 'ObsoleteBy', 'ObsoleteAt'];
  // five tracker tabs
  ITEM_TABS.forEach(t => {
    if (t === 'Instruments') {
      ensureTab_('Instruments', ['Code', 'Barcode', 'Name', 'Category', 'Supplier', 'Location',
        'Unit', 'Qty', 'ReorderLevel', 'UnitCost', 'Expiry', 'Batch', 'Notes', 'Status',
        'QtyInTray', 'CyclesToDate', 'Obsolete', 'ObsoleteBy', 'ObsoleteAt']);
    } else {
      ensureTab_(t, ITEM_HEADERS);
    }
  });
  // supporting tabs
  ensureTab_('Transactions', ['Timestamp', 'Direction', 'Tracker', 'Code', 'Name', 'Qty',
    'By', 'Batch', 'Expiry', 'Note', 'Activity']);
  ensureTab_('Requests', ['Timestamp', 'By', 'Item', 'Qty', 'Size', 'Status',
    'HandledBy', 'DateResponded', 'Remarks']);
  ensureTab_('BarcodeLinks', ['Barcode', 'Tracker', 'Code']);
  ensureTab_('Alerts', ['Timestamp', 'Tracker', 'Code', 'Name', 'Level', 'Qty',
    'ReorderLevel', 'Acknowledged', 'AckBy', 'AckAt', 'Escalated']);
  ensureTab_('Stocktakes', ['Timestamp', 'Type', 'Tracker', 'Store', 'By', 'Code', 'Name',
    'Expected', 'Counted', 'Variance', 'UnitCost', 'VarianceValue']);
  // Settings with the keys the app expects, seeded blank
  if (!ss.getSheetByName('Settings')) {
    const setSheet = ensureTab_('Settings', ['Key', 'Value', 'Description']);
    setSheet.getRange(2, 1, 12, 3).setValues([
      ['app_name', 'Bollin Clinic Inventory', 'Name shown in emails'],
      ['alert_email', '', 'Low/out/expiry alert recipient(s), comma-separated'],
      ['escalation_email', '', 'Second-level recipient if an alert is not acknowledged'],
      ['ack_hours', '48', 'Hours before an unacknowledged alert escalates'],
      ['expiry_days', '90', 'Warn when items expire within this many days'],
      ['slow_days', '', 'Optional: days without movement to flag slow stock'],
      ['activity_email', '', 'Midnight activity-log recipient(s), comma-separated'],
      ['request_email', '', 'Notified when a new request is submitted, comma-separated'],
      ['implant_email', '', 'Notified when a new implant order is created, comma-separated'],
      ['', '', ''], ['', '', ''], ['', '', '']
    ]);
  }
  // Users tab seeded with three starter accounts (so you can sign in immediately)
  if (!ss.getSheetByName('Users')) {
    const uSheet = ensureTab_('Users', USER_HEADERS);
    uSheet.getRange(2, 1, 3, USER_HEADERS.length).setValues([
      ['yasar', 'ChangeMe123', 'admin', 'Yasar', 'yes'],
      ['stockteam', 'ChangeMe123', 'staff', 'Stock Team', 'yes'],
      ['scrubs', 'ChangeMe123', 'common', 'Scrub Team', 'yes']
    ]);
  }

  // 1. Implants tab (create, or append any missing columns)
  let imp = ss.getSheetByName('Implants');
  if (!imp) {
    imp = ss.insertSheet('Implants');
    imp.getRange(1, 1, 1, IMPLANT_HEADERS.length).setValues([IMPLANT_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    imp.setFrozenRows(1);
  } else {
    const have = imp.getRange(1, 1, 1, Math.max(imp.getLastColumn(), 1)).getValues()[0].map(String);
    IMPLANT_HEADERS.forEach(hd => {
      if (have.indexOf(hd) < 0) {
        const c2 = imp.getLastColumn() + 1;
        imp.getRange(1, c2).setValue(hd)
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
        have.push(hd);
      }
    });
  }
  // 1b. DispatchLog tab (sterilisation) — create, or append any missing columns
  let dl = ss.getSheetByName('DispatchLog');
  if (!dl) {
    dl = ss.insertSheet('DispatchLog');
    dl.getRange(1, 1, 1, DISPATCH_HEADERS.length).setValues([DISPATCH_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    dl.setFrozenRows(1);
  } else {
    const haveD = dl.getRange(1, 1, 1, Math.max(dl.getLastColumn(), 1)).getValues()[0].map(String);
    DISPATCH_HEADERS.forEach(hd => {
      if (haveD.indexOf(hd) < 0) {
        const c3 = dl.getLastColumn() + 1;
        dl.getRange(1, c3).setValue(hd)
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
        haveD.push(hd);
      }
    });
  }
  // 1b2. Instruments register: ensure Expiry and Status columns exist
  const inst = ss.getSheetByName('Instruments');
  if (inst) {
    const haveI = inst.getRange(1, 1, 1, Math.max(inst.getLastColumn(), 1)).getValues()[0].map(String);
    ['Expiry', 'Status'].forEach(hd => {
      if (haveI.indexOf(hd) < 0) {
        const c4 = inst.getLastColumn() + 1;
        inst.getRange(1, c4).setValue(hd)
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
        haveI.push(hd);
      }
    });
  }
  // 1c. Users tab
  if (!ss.getSheetByName('Users')) {
    const us = ss.insertSheet('Users');
    us.getRange(1, 1, 1, USER_HEADERS.length).setValues([USER_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    us.setFrozenRows(1);
    us.getRange(2, 1, 3, USER_HEADERS.length).setValues([
      ['yasar', 'ChangeMe123', 'admin', 'Yasar', 'yes'],
      ['stockteam', 'ChangeMe123', 'staff', 'Stock Team', 'yes'],
      ['scrubs', 'ChangeMe123', 'common', 'Scrub Team', 'yes']
    ]);
    us.getRange(6, 1).setValue(
      'Roles: admin = everything · staff = all except adding/editing items · common = scan in/out + log used only, no values. ' +
      'Type an initial password in the Password column — it is replaced by a secure hash the first time the person signs in. Active: yes/no.')
      .setFontStyle('italic').setFontSize(9);
  }
  // 1d2. Obsolete columns on every tracker tab
  ITEM_TABS.forEach(t => {
    const shT = ss.getSheetByName(t);
    if (!shT) return;
    let haveO = shT.getRange(1, 1, 1, Math.max(shT.getLastColumn(), 1)).getValues()[0].map(String);
    ['Obsolete', 'ObsoleteBy', 'ObsoleteAt'].forEach(hd => {
      if (haveO.indexOf(hd) < 0) {
        shT.getRange(1, shT.getLastColumn() + 1).setValue(hd)
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
        haveO.push(hd);
      }
    });
  });
  // 1d3. Stores tab (managed store list)
  if (!ss.getSheetByName('Stores')) {
    const sto = ss.insertSheet('Stores');
    sto.getRange(1, 1, 1, 2).setValues([['Tracker', 'Store']])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    sto.setFrozenRows(1);
    sto.getRange(3, 1).setValue(
      'Stores also appear automatically from item locations; rows here add empty stores before items move in.')
      .setFontStyle('italic').setFontSize(9);
  }
  // 1d4. Assets tab
  if (!ss.getSheetByName('Assets')) {
    const asx = ss.insertSheet('Assets');
    asx.getRange(1, 1, 1, ASSET_HEADERS.length).setValues([ASSET_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    asx.setFrozenRows(1);
  }
  // 1d5. GasChecks tab
  if (!ss.getSheetByName('GasChecks')) {
    const gcx = ss.insertSheet('GasChecks');
    gcx.getRange(1, 1, 1, GASCHECK_HEADERS.length).setValues([GASCHECK_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    gcx.setFrozenRows(1);
  }
  // 1d6. Procedure case-costing tabs
  if (!ss.getSheetByName('Procedures')) {
    const pr = ss.insertSheet('Procedures');
    pr.getRange(1, 1, 1, PROC_HEADERS.length).setValues([PROC_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    pr.setFrozenRows(1);
  }
  // Rota tab (theatre staffing — superadmin only). Idempotent: create if missing,
  // and if it already exists, append any NEW columns without disturbing existing data.
  {
    let rt = ss.getSheetByName('Rota');
    if (!rt) {
      rt = ss.insertSheet('Rota');
      rt.getRange(1, 1, 1, ROTA_HEADERS.length).setValues([ROTA_HEADERS])
        .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
      rt.setFrozenRows(1);
      rt.getRange('A:A').setNumberFormat('@');
    } else {
      const existing = rt.getRange(1, 1, 1, Math.max(1, rt.getLastColumn())).getValues()[0].map(String);
      const missing = ROTA_HEADERS.filter(function (hn) { return existing.indexOf(hn) < 0; });
      if (missing.length) {
        rt.getRange(1, existing.length + 1, 1, missing.length).setValues([missing])
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
      }
      rt.getRange('A:A').setNumberFormat('@');
    }
  }
  // ensure CartJSON + Room columns exist on Procedures (idempotent)
  {
    const pr = ss.getSheetByName('Procedures');
    ['CartJSON','Room'].forEach(function (col) {
      const ph = pr.getRange(1, 1, 1, Math.max(pr.getLastColumn(),1)).getValues()[0].map(String);
      if (ph.indexOf(col) < 0)
        pr.getRange(1, pr.getLastColumn() + 1).setValue(col)
          .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    });
  }
  // Samples tab (specimen collection log)
  {
    let sm = ss.getSheetByName('Samples');
    if (!sm) {
      sm = ss.insertSheet('Samples');
      sm.getRange(1, 1, 1, SAMPLE_HEADERS.length).setValues([SAMPLE_HEADERS])
        .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
      sm.setFrozenRows(1);
      sm.getRange('A:A').setNumberFormat('@');
    } else {
      const ex = sm.getRange(1, 1, 1, Math.max(1, sm.getLastColumn())).getValues()[0].map(String);
      const miss = SAMPLE_HEADERS.filter(function (hn) { return ex.indexOf(hn) < 0; });
      if (miss.length) sm.getRange(1, ex.length + 1, 1, miss.length).setValues([miss])
        .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    }
  }
  if (!ss.getSheetByName('ProcedureLines')) {
    const pl = ss.insertSheet('ProcedureLines');
    pl.getRange(1, 1, 1, PROCLINE_HEADERS.length).setValues([PROCLINE_HEADERS])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    pl.setFrozenRows(1);
  }
  // 1e. Transactions tab: ensure Activity column
  const tx = ss.getSheetByName('Transactions');
  if (tx) {
    const haveT = tx.getRange(1, 1, 1, Math.max(tx.getLastColumn(), 1)).getValues()[0].map(String);
    if (haveT.indexOf('Activity') < 0) {
      tx.getRange(1, tx.getLastColumn() + 1).setValue('Activity')
        .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    }
  }
  // 1f. Settings: activity_email row
  const st = ss.getSheetByName('Settings');
  if (st) {
    const keys = st.getRange(1, 1, Math.max(st.getLastRow(), 1), 1).getValues().map(r => String(r[0]));
    if (keys.indexOf('activity_email') < 0) {
      st.appendRow(['activity_email', '', 'Nightly midnight activity-log email recipient(s), comma-separated (falls back to alert_email if empty)']);
    }
    if (keys.indexOf('request_email') < 0) {
      st.appendRow(['request_email', '', 'Email(s) notified instantly when a new request is submitted, comma-separated']);
    }
    if (keys.indexOf('implant_email') < 0) {
      st.appendRow(['implant_email', '', 'Email(s) notified instantly when a new implant order is created, comma-separated']);
    }
    if (keys.indexOf('sticker_margins') < 0) {
      st.appendRow(['sticker_margins', '', 'Saved sticker-sheet margin preset (JSON) from the Sticker printer']);
    }
  }
  // 2. Requests tab: old schema (Tracker/Code, HandledAt) -> new (Size, DateResponded, Remarks)
  const sh = ss.getSheetByName('Requests');
  const head = sh.getRange(1, 1, 1, Math.max(sh.getLastColumn(), 1)).getValues()[0].map(String);
  const NEW = ['Timestamp','By','Item','Qty','Size','Status','HandledBy','DateResponded','Remarks'];
  if (head.join() !== NEW.join()) {
    const old = sh.getDataRange().getValues();
    const idx = {}; head.forEach((h, i) => idx[h] = i);
    const rows = old.slice(1).filter(r => r.join('') !== '').map(r => [
      r[idx['Timestamp']] || '', r[idx['By']] || '',
      r[idx['Item']] || '', r[idx['Qty']] || '',
      '',                                            // Size (new)
      r[idx['Status']] === 'Issued' ? 'Received' : (r[idx['Status']] || 'Requested'),
      r[idx['HandledBy']] || '',
      r[idx['HandledAt']] || '', ''                  // DateResponded, Remarks
    ]);
    sh.clear();
    sh.getRange(1, 1, 1, NEW.length).setValues([NEW])
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
    if (rows.length) sh.getRange(2, 1, rows.length, NEW.length).setValues(rows);
    sh.setFrozenRows(1);
  }
  return 'Migration complete';
}

function ackAlert_(q) {
  const sh = ss_().getSheetByName('Alerts');
  sh.getRange(q.row, 7).setValue('Acknowledged');
  sh.getRange(q.row, 8).setValue(q.by || '');
  sh.getRange(q.row, 9).setValue(new Date());
  logAct_('Alert acknowledged', {tracker: String(sh.getRange(q.row, 2).getValue() || ''),
    name: String(sh.getRange(q.row, 4).getValue() || ''), by: q.by});
  return { ok: true };
}

function ackFromEmail_(rowStr) {
  const row = Number(rowStr);
  if (row >= 2) {
    const sh = ss_().getSheetByName('Alerts');
    if (sh.getRange(row, 7).getValue() === 'Sent') {
      sh.getRange(row, 7).setValue('Acknowledged');
      sh.getRange(row, 8).setValue('Via email link');
      sh.getRange(row, 9).setValue(new Date());
    }
  }
  return HtmlService.createHtmlOutput(
    '<div style="font-family:sans-serif;padding:40px;text-align:center">' +
    '<h2>✅ Alert acknowledged</h2><p>Thank you — no escalation will be sent.</p></div>');
}

function stocktake_(q) {
  // q: {checkType:'Month-end'|'Annual', by, entries:[{tracker,code,item,expected,counted,store}], apply:true|false}
  const sh = ss_().getSheetByName('Stocktakes');
  const ts = new Date();
  (q.entries || []).forEach(en => {
    const variance = Number(en.counted) - Number(en.expected);
    sh.appendRow([ts, q.checkType || 'Month-end', en.store || '', en.tracker,
                  en.code, en.item, en.expected, en.counted, variance, q.by || 'Unknown']);
    if (q.apply && variance !== 0 && en.tracker !== 'Instruments') {
      try {
        const it = en.row ? itemAtRow_(en.tracker, Number(en.row)) : findItem_(en.tracker, en.code);
        it.sh.getRange(it.row, col_(it.head, 'Qty')).setValue(Number(en.counted));
      } catch (err) { /* item deleted mid-count — recorded but not applied */ }
    }
  });
  logAct_('Stocktake saved', {tracker: (q.entries && q.entries[0] ? q.entries[0].tracker : ''),
    name: (q.checkType || 'Month-end') + ' check', qty: (q.entries || []).length, by: q.by,
    note: (q.entries || []).filter(e => Number(e.counted) !== Number(e.expected)).length + ' variance(s)' +
          (q.apply ? ', stock adjusted' : '')});
  return { ok: true, saved: (q.entries || []).length };
}

function clearBarcode_(q) {
  // q: {tracker, row, barcode} — clears the Barcode cell and any BarcodeLinks rows
  const sh = ss_().getSheetByName(q.tracker);
  if (!sh) return { ok: false, error: 'No tab: ' + q.tracker };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const cBar = head.indexOf('Barcode') + 1;
  if (cBar && q.row) sh.getRange(q.row, cBar).setValue('');
  if (q.barcode) {
    const bl = ss_().getSheetByName('BarcodeLinks');
    const vals = bl.getDataRange().getValues();
    for (let r = vals.length - 1; r >= 1; r--) {
      if (String(vals[r][0]) === String(q.barcode)) bl.deleteRow(r + 1);
    }
  }
  logAct_('Barcode removed', {tracker: q.tracker, code: q.barcode || '', note: 'Label cleared for regeneration'});
  return { ok: true };
}

/* ============================ gas room checks ============================ */

const GASCHECK_HEADERS = ['Timestamp','Date','By',
  'O2_LeftBank','O2_RightBank','O2_Pipeline','O2_InUseBank','O2_DeliveryBooked',
  'Air_LeftBank','Air_RightBank','Air_Pipeline','Air_InUseBank','Air_DeliveryBooked',
  'Helium_Total','Helium_Full','Helium_Empty',
  'TrolleyO2_Total','TrolleyO2_Full','TrolleyO2_Empty','TrolleyO2_NextDelivery',
  'Vacuum_DutyPump','Vacuum_Status','Airflow_TH1_Off','Airflow_TH2_Off','Notes'];

function gasCheckAdd_(q) {
  const sh = ss_().getSheetByName('GasChecks');
  if (!sh) return { ok: false, error: 'GasChecks tab missing — run migrate()' };
  const f = q.fields || {};
  f.Timestamp = new Date();
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  sh.appendRow(head.map(h => {
    let v = f[h];
    if (v === undefined || v === null) return '';
    if ((h === 'Date' || h === 'TrolleyO2_NextDelivery') && v) return new Date(v);
    return v;
  }));
  logAct_('Gas room check', {tracker: 'Gas Room', by: f.By,
    name: 'Daily check', note:
      'O2 L' + (f.O2_LeftBank ?? '—') + '/R' + (f.O2_RightBank ?? '—') +
      (f.Air_LeftBank !== undefined && f.Air_LeftBank !== '' ? ' · Air L' + f.Air_LeftBank + '/R' + (f.Air_RightBank ?? '—') : '') +
      ' · Pumps ' + (f.Vacuum_Status || '—')});
  return { ok: true, row: sh.getLastRow() };
}

/* ======================= procedure case costing ========================= */

const PROC_HEADERS = ['ProcedureID','Date','Surgeon','Procedure','PatientRef','StartedBy',
  'Status','StartTime','EndTime','TotalCost','Notes','CartJSON','Room'];
const PROCLINE_HEADERS = ['ProcedureID','Timestamp','Tracker','Code','Name','Qty','UnitCost','LineCost','By'];
const SAMPLE_HEADERS = ['SampleID','Date','PatientInitials','PATNumber','Surgeon','SpecimenNo',
  'SampleDetails','Category','Formalin','DateCollected','DateSent','DateResult','By','Notes'];

function procForRole_(session) {
  const rows = readTab_('Procedures');
  if (!session) return [];
  if (ROLE_RANK[session.role] >= 2) return rows;
  return rows.map(function (r) {
    var o = {}; Object.keys(r).forEach(function (k) { o[k] = r[k]; });
    o.TotalCost = ''; return o;
  });
}
function procLinesForRole_(session) {
  const rows = readTab_('ProcedureLines').slice(-500);
  if (!session) return [];
  if (ROLE_RANK[session.role] >= 2) return rows;
  return rows.map(function (r) {
    var o = {}; Object.keys(r).forEach(function (k) { o[k] = r[k]; });
    o.UnitCost = ''; o.LineCost = ''; return o;
  });
}

function procStart_(q) {
  const sh = ss_().getSheetByName('Procedures');
  if (!sh) return { ok: false, error: 'Procedures tab missing — run migrate()' };
  const id = 'PROC-' + Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyyMMdd-HHmmss');
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const map = { ProcedureID: id, Date: q.date ? new Date(q.date) : new Date(),
    Surgeon: q.surgeon || '', Procedure: q.procedure || '', PatientRef: q.patientRef || '',
    StartedBy: q.by || CURRENT_USER || '', Status: 'Open', StartTime: new Date(),
    EndTime: '', TotalCost: 0, Notes: q.notes || '', Room: q.room || '' };
  sh.appendRow(head.map(h => map[h] !== undefined ? map[h] : ''));
  logAct_('Procedure started', {tracker: 'Procedure', code: id,
    name: (q.surgeon || '') + ' — ' + (q.procedure || ''), by: q.by,
    note: 'Case costing opened' + (q.patientRef ? ' · ' + q.patientRef : '')});
  return { ok: true, procedureId: id };
}

function procConsume_(q) {
  // q: {procedureId, tracker, code, name, qty, by}
  // Records a line against the procedure. Stock is decremented separately by the
  // normal move action, so this does NOT touch stock itself.
  // The unit cost is looked up authoritatively from the item (the client may not
  // have it — e.g. scrub 'common' logins have costs stripped), so costing is correct
  // no matter who runs the procedure.
  const sh = ss_().getSheetByName('ProcedureLines');
  if (!sh) return { ok: false, error: 'ProcedureLines tab missing — run migrate()' };
  const qty = Math.max(1, Number(q.qty) || 1);
  let uc = '';
  try {
    const tabName = q.tracker && q.tracker.charAt(0).toUpperCase() + q.tracker.slice(1);
    const its = ss_().getSheetByName(tabName);
    if (its) {
      const vals = its.getDataRange().getValues();
      const head = vals[0].map(String);
      const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'),
            cName = head.indexOf('Name'), cCost = head.indexOf('UnitCost');
      for (let r = 1; r < vals.length; r++) {
        const vc = cCode >= 0 ? String(vals[r][cCode] || '').trim() : '';
        const vb = cBar >= 0 ? String(vals[r][cBar] || '').trim() : '';
        const vn = cName >= 0 ? String(vals[r][cName] || '').trim() : '';
        if ((q.code && (vc === String(q.code).trim() || vb === String(q.code).trim())) ||
            (!q.code && q.name && vn === String(q.name).trim())) {
          const cv = cCost >= 0 ? vals[r][cCost] : '';
          uc = (cv === '' || cv == null) ? '' : Number(cv);
          break;
        }
      }
    }
  } catch (e) { uc = ''; }
  const line = uc === '' ? '' : Math.round(uc * qty * 100) / 100;
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const map = { ProcedureID: q.procedureId || '', Timestamp: new Date(), Tracker: q.tracker || '',
    Code: q.code || '', Name: q.name || '', Qty: qty, UnitCost: uc, LineCost: line, By: q.by || CURRENT_USER || '' };
  sh.appendRow(head.map(h => map[h] !== undefined ? map[h] : ''));
  // keep the procedure's running total up to date
  if (line !== '') {
    const ps = ss_().getSheetByName('Procedures');
    const pv = ps.getDataRange().getValues();
    const pHead = pv[0].map(String);
    const idC = pHead.indexOf('ProcedureID'), tcC = pHead.indexOf('TotalCost');
    for (let r = 1; r < pv.length; r++) {
      if (String(pv[r][idC]) === String(q.procedureId)) {
        const cur = Number(pv[r][tcC]) || 0;
        ps.getRange(r + 1, tcC + 1).setValue(Math.round((cur + line) * 100) / 100);
        break;
      }
    }
  }
  return { ok: true, lineCost: line };
}

// ---- security net: persist an in-progress cart to the sheet (temporary save) ----
// Stored as a JSON blob on the Procedures row (CartJSON column), so a refresh/crash
// never loses scanned items. Does NOT touch stock.
function procSaveCart_(q) {
  // q: {procedureId, cart:[{tracker,code,barcode,name,qty,unitCost}], by}
  const sh = ss_().getSheetByName('Procedures');
  if (!sh) return { ok: false, error: 'Procedures tab missing' };
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  let cCart = head.indexOf('CartJSON');
  if (cCart < 0) {                                   // add the column on demand
    cCart = head.length;
    sh.getRange(1, cCart + 1).setValue('CartJSON')
      .setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
  }
  const idC = head.indexOf('ProcedureID');
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][idC]) === String(q.procedureId)) {
      sh.getRange(r + 1, cCart + 1).setValue(JSON.stringify(q.cart || []));
      return { ok: true, saved: (q.cart || []).length };
    }
  }
  return { ok: false, error: 'Procedure not found' };
}

function procGetCart_(q) {
  const sh = ss_().getSheetByName('Procedures');
  if (!sh) return { ok: false, cart: [] };
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const idC = head.indexOf('ProcedureID'), cCart = head.indexOf('CartJSON');
  if (cCart < 0) return { ok: true, cart: [] };
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][idC]) === String(q.procedureId)) {
      try { return { ok: true, cart: JSON.parse(vals[r][cCart] || '[]') }; }
      catch (e) { return { ok: true, cart: [] }; }
    }
  }
  return { ok: true, cart: [] };
}

// ---- atomic end: decrement stock for every line, record lines, close — all or clearly reported ----
function procConsumeBatch_(q) {
  // q: {procedureId, lines:[{tracker,code,barcode,name,qty}], by}
  // Runs entirely server-side in one request so a client refresh can't interrupt it.
  const lines = q.lines || [];
  const results = [], failed = [];
  const lineSheet = ss_().getSheetByName('ProcedureLines');
  const lineHead = lineSheet.getRange(1, 1, 1, lineSheet.getLastColumn()).getValues()[0].map(String);
  let runningTotal = 0;

  lines.forEach(function (l) {
    const qty = Math.max(1, Number(l.qty) || 1);
    // resolve the item row: prefer code/barcode, fall back to exact name (blank-code meds)
    let it = null;
    try {
      const tabName = l.tracker.charAt(0).toUpperCase() + l.tracker.slice(1);
      const sh = ss_().getSheetByName(tabName);
      if (!sh) throw 'no tab';
      const vals = sh.getDataRange().getValues();
      const head = vals[0].map(String);
      const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'),
            cName = head.indexOf('Name'), cQty = head.indexOf('Qty'), cCost = head.indexOf('UnitCost');
      const wantCode = String(l.code || '').trim(), wantBar = String(l.barcode || '').trim(),
            wantName = String(l.name || '').trim().toLowerCase();
      let rowIdx = -1, byName = -1;
      for (let r = 1; r < vals.length; r++) {
        const vc = cCode >= 0 ? String(vals[r][cCode] || '').trim() : '';
        const vb = cBar >= 0 ? String(vals[r][cBar] || '').trim() : '';
        const vn = cName >= 0 ? String(vals[r][cName] || '').trim().toLowerCase() : '';
        if ((wantCode && vc && vc === wantCode) || (wantBar && vb && vb === wantBar)) { rowIdx = r; break; }
        if (byName < 0 && wantName && vn === wantName) byName = r;
      }
      if (rowIdx < 0) rowIdx = byName;
      if (rowIdx < 0) { failed.push({ name: l.name, reason: 'not found in ' + tabName }); return; }
      // decrement stock
      const cur = Number(vals[rowIdx][cQty]) || 0;
      const newQty = cur - qty;
      sh.getRange(rowIdx + 1, cQty + 1).setValue(newQty < 0 ? 0 : newQty);
      const uc = cCost >= 0 && vals[rowIdx][cCost] !== '' && vals[rowIdx][cCost] != null ? Number(vals[rowIdx][cCost]) : '';
      const lineCost = uc === '' ? '' : Math.round(uc * qty * 100) / 100;
      if (lineCost !== '') runningTotal += lineCost;
      // record procedure line
      const map = { ProcedureID: q.procedureId, Timestamp: new Date(), Tracker: l.tracker,
        Code: l.code || '', Name: l.name || '', Qty: qty, UnitCost: uc, LineCost: lineCost, By: q.by || CURRENT_USER || '' };
      lineSheet.appendRow(lineHead.map(function (h) { return map[h] !== undefined ? map[h] : ''; }));
      // log the stock movement
      logAct_('Stock out', { dir: 'out', tracker: tabName, code: l.code || '', name: l.name,
        qty: qty, by: q.by, note: 'Consumed — procedure ' + q.procedureId });
      results.push({ name: l.name, qty: qty, newQty: newQty < 0 ? 0 : newQty });
    } catch (e) {
      failed.push({ name: l.name, reason: String(e) });
    }
  });

  // update procedure total + close it (even if some lines failed, we close and report)
  const ps = ss_().getSheetByName('Procedures');
  const pv = ps.getDataRange().getValues();
  const pHead = pv[0].map(String);
  const idC = pHead.indexOf('ProcedureID'), tcC = pHead.indexOf('TotalCost'),
        stC = pHead.indexOf('Status'), etC = pHead.indexOf('EndTime'), cartC = pHead.indexOf('CartJSON');
  for (let r = 1; r < pv.length; r++) {
    if (String(pv[r][idC]) === String(q.procedureId)) {
      if (tcC >= 0) ps.getRange(r + 1, tcC + 1).setValue(Math.round(runningTotal * 100) / 100);
      if (stC >= 0) ps.getRange(r + 1, stC + 1).setValue('Closed');
      if (etC >= 0) ps.getRange(r + 1, etC + 1).setValue(new Date());
      if (cartC >= 0) ps.getRange(r + 1, cartC + 1).setValue('');   // clear saved cart
      break;
    }
  }
  logAct_('Procedure ended', { tracker: 'Procedure', code: q.procedureId,
    name: 'Case closed', by: q.by,
    note: results.length + ' line(s) consumed · Total £' + runningTotal.toFixed(2) +
      (failed.length ? ' · ' + failed.length + ' FAILED' : '') });
  return { ok: failed.length === 0, consumed: results.length, failed: failed, total: runningTotal };
}

// ---- shared: find a Procedures row by id -> {sh, head, rowIdx (0-based in vals), vals} or null ----
function procRow_(procedureId) {
  const sh = ss_().getSheetByName('Procedures');
  if (!sh) return null;
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const idC = head.indexOf('ProcedureID');
  for (let r = 1; r < vals.length; r++)
    if (String(vals[r][idC]) === String(procedureId)) return { sh: sh, head: head, r: r, vals: vals[r] };
  return null;
}

// ---- shared: restore stock for every ProcedureLines row of a procedure, then delete those rows ----
// Resolution mirrors procConsumeBatch_: Code -> Barcode -> exact Name (blank-code meds safe).
function procRestoreLines_(procedureId, by) {
  const ls = ss_().getSheetByName('ProcedureLines');
  if (!ls) return { restored: [], failed: [], cart: [] };
  const lv = ls.getDataRange().getValues();
  const lh = lv[0].map(String);
  const cId = lh.indexOf('ProcedureID'), cTr = lh.indexOf('Tracker'), cCo = lh.indexOf('Code'),
        cNa = lh.indexOf('Name'), cQt = lh.indexOf('Qty'), cUc = lh.indexOf('UnitCost');
  const mine = [];
  for (let r = 1; r < lv.length; r++)
    if (String(lv[r][cId]) === String(procedureId))
      mine.push({ rowNum: r + 1, tracker: String(lv[r][cTr] || ''), code: String(lv[r][cCo] || ''),
        name: String(lv[r][cNa] || ''), qty: Math.max(1, Number(lv[r][cQt]) || 1),
        unitCost: lv[r][cUc] === '' || lv[r][cUc] == null ? '' : Number(lv[r][cUc]) });
  const restored = [], failed = [];
  mine.forEach(function (l) {
    try {
      const tabName = l.tracker.charAt(0).toUpperCase() + l.tracker.slice(1);
      const sh = ss_().getSheetByName(tabName);
      if (!sh) throw 'no tab ' + tabName;
      const vals = sh.getDataRange().getValues();
      const head = vals[0].map(String);
      const cCode = head.indexOf('Code'), cBar = head.indexOf('Barcode'),
            cName = head.indexOf('Name'), cQty = head.indexOf('Qty');
      const wc = l.code.trim(), wn = l.name.trim().toLowerCase();
      let rowIdx = -1, byName = -1;
      for (let r = 1; r < vals.length; r++) {
        const vc = cCode >= 0 ? String(vals[r][cCode] || '').trim() : '';
        const vb = cBar >= 0 ? String(vals[r][cBar] || '').trim() : '';
        const vn = cName >= 0 ? String(vals[r][cName] || '').trim().toLowerCase() : '';
        if (wc && ((vc && vc === wc) || (vb && vb === wc))) { rowIdx = r; break; }
        if (byName < 0 && wn && vn === wn) byName = r;
      }
      if (rowIdx < 0) rowIdx = byName;
      if (rowIdx < 0) { failed.push({ name: l.name, reason: 'not found in ' + tabName }); return; }
      const cur = Number(vals[rowIdx][cQty]) || 0;
      sh.getRange(rowIdx + 1, cQty + 1).setValue(cur + l.qty);
      logAct_('Stock in', { dir: 'in', tracker: tabName, code: l.code, name: l.name, qty: l.qty,
        by: by, note: 'Returned to stock — procedure ' + procedureId + ' reopened/deleted' });
      restored.push(l);
    } catch (e) { failed.push({ name: l.name, reason: String(e) }); }
  });
  // delete the lines bottom-up so row numbers stay valid
  mine.slice().reverse().forEach(function (l) { ls.deleteRow(l.rowNum); });
  const cart = mine.map(function (l) { return { tracker: l.tracker, code: l.code, barcode: '',
    name: l.name, qty: l.qty, unitCost: l.unitCost }; });
  return { restored: restored, failed: failed, cart: cart };
}

// ---- admin: reopen a closed procedure for editing (stock is put BACK; re-End re-consumes) ----
function procReopen_(q) {
  const p = procRow_(q.procedureId);
  if (!p) return { ok: false, error: 'Procedure not found' };
  const stC = p.head.indexOf('Status');
  if (String(p.vals[stC]) === 'Open') return { ok: false, error: 'Procedure is already open' };
  const res = procRestoreLines_(q.procedureId, q.by);
  const etC = p.head.indexOf('EndTime'), tcC = p.head.indexOf('TotalCost'), cjC = p.head.indexOf('CartJSON');
  p.sh.getRange(p.r + 1, stC + 1).setValue('Open');
  if (etC >= 0) p.sh.getRange(p.r + 1, etC + 1).setValue('');
  if (tcC >= 0) p.sh.getRange(p.r + 1, tcC + 1).setValue(0);
  if (cjC >= 0) p.sh.getRange(p.r + 1, cjC + 1).setValue(JSON.stringify(res.cart));
  logAct_('Procedure reopened', { tracker: 'Procedure', code: q.procedureId, name: 'Reopened for editing',
    by: q.by, note: res.restored.length + ' line(s) returned to stock' +
      (res.failed.length ? ' · ' + res.failed.length + ' could not be restored' : '') });
  return { ok: true, cart: res.cart, failed: res.failed };
}

// ---- admin: delete a procedure entirely; consumed stock goes back to inventories ----
function procDelete_(q) {
  const p = procRow_(q.procedureId);
  if (!p) return { ok: false, error: 'Procedure not found' };
  const stC = p.head.indexOf('Status');
  const wasClosed = String(p.vals[stC]) !== 'Open';
  const res = wasClosed ? procRestoreLines_(q.procedureId, q.by)
                        : { restored: [], failed: [], cart: [] };
  if (!wasClosed) {
    // open procedures have no consumed lines, but clear any stray ones defensively
    procRestoreLines_(q.procedureId, q.by);
  }
  p.sh.deleteRow(p.r + 1);
  logAct_('Procedure deleted', { tracker: 'Procedure', code: q.procedureId,
    name: String(p.vals[p.head.indexOf('Surgeon')] || '') + ' — ' + String(p.vals[p.head.indexOf('Procedure')] || ''),
    by: q.by, note: (wasClosed ? res.restored.length + ' line(s) returned to stock' : 'No stock had been consumed') +
      (res.failed.length ? ' · ' + res.failed.length + ' could not be restored' : '') });
  return { ok: true, restored: res.restored.length, failed: res.failed };
}

// ---- any role: cancel an OPEN procedure started by mistake (nothing was consumed) ----
function procCancel_(q) {
  const p = procRow_(q.procedureId);
  if (!p) return { ok: true, note: 'not on sheet' };   // local-only id: nothing to do
  const stC = p.head.indexOf('Status');
  if (String(p.vals[stC]) !== 'Open')
    return { ok: false, error: 'Only an open procedure can be cancelled' };
  p.sh.deleteRow(p.r + 1);
  logAct_('Procedure cancelled', { tracker: 'Procedure', code: q.procedureId,
    name: String(p.vals[p.head.indexOf('Surgeon')] || '') + ' — ' + String(p.vals[p.head.indexOf('Procedure')] || ''),
    by: q.by, note: 'Started by mistake — no stock was consumed' });
  return { ok: true };
}

// ---- admin: correct surgeon / procedure / patient ref / date ----
function procUpdateMeta_(q) {
  const p = procRow_(q.procedureId);
  if (!p) return { ok: false, error: 'Procedure not found' };
  const set = function (col, val) { const c = p.head.indexOf(col);
    if (c >= 0 && val !== undefined) p.sh.getRange(p.r + 1, c + 1).setValue(val); };
  const changes = [];
  ['Surgeon', 'Procedure', 'PatientRef'].forEach(function (k) {
    const key = k.charAt(0).toLowerCase() + k.slice(1);
    if (q[key] !== undefined && String(q[key]) !== String(p.vals[p.head.indexOf(k)] || '')) {
      set(k, q[key]); changes.push(k.toLowerCase() + ' → "' + q[key] + '"');
    }
  });
  if (q.date !== undefined && q.date) { set('Date', new Date(q.date)); changes.push('date → ' + q.date); }
  logAct_('Procedure details edited', { tracker: 'Procedure', code: q.procedureId,
    name: q.surgeon || '', by: q.by, note: changes.join('; ') || 'No changes' });
  return { ok: true };
}

function procEnd_(q) {
  const sh = ss_().getSheetByName('Procedures');
  if (!sh) return { ok: false, error: 'Procedures tab missing' };
  const vals = sh.getDataRange().getValues();
  const head = vals[0].map(String);
  const idC = head.indexOf('ProcedureID'), stC = head.indexOf('Status'),
        etC = head.indexOf('EndTime'), tcC = head.indexOf('TotalCost');
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][idC]) === String(q.procedureId)) {
      sh.getRange(r + 1, stC + 1).setValue('Closed');
      sh.getRange(r + 1, etC + 1).setValue(new Date());
      logAct_('Procedure ended', {tracker: 'Procedure', code: q.procedureId,
        name: String(vals[r][head.indexOf('Surgeon')] || '') + ' — ' + String(vals[r][head.indexOf('Procedure')] || ''),
        by: q.by, note: 'Total £' + (Number(vals[r][tcC]) || 0).toFixed(2)});
      return { ok: true, total: Number(vals[r][tcC]) || 0 };
    }
  }
  return { ok: false, error: 'Procedure not found' };
}

/* =============================== assets ================================= */

const ASSET_HEADERS = ['Name','SerialNumber','Function','Supplier','SupplierContact',
  'Location','LastMaintenance','NextMaintenanceDue','Status','Notes'];

function assetAdd_(q) {
  const sh = ss_().getSheetByName('Assets');
  if (!sh) return { ok: false, error: 'Assets tab missing — run migrate()' };
  const f = q.fields || {};
  if (!f.Name) return { ok: false, error: 'Name required' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  sh.appendRow(head.map(h => {
    let v = f[h];
    if (v === undefined || v === null) return '';
    if (h.indexOf('Maintenance') >= 0 && v) return new Date(v);
    return v;
  }));
  logAct_('Asset added', {tracker: 'Assets', code: f.SerialNumber || '', name: f.Name,
    note: 'Status: ' + (f.Status || 'Working')});
  return { ok: true, row: sh.getLastRow() };
}

function assetUpdate_(q) {
  const sh = ss_().getSheetByName('Assets');
  if (!sh) return { ok: false, error: 'Assets tab missing' };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  Object.keys(q.fields || {}).forEach(h => {
    const c2 = head.indexOf(h);
    if (c2 < 0) return;
    let v = q.fields[h];
    if (v === null || v === undefined) v = '';
    if (h.indexOf('Maintenance') >= 0 && v) v = new Date(v);
    sh.getRange(q.row, c2 + 1).setValue(v);
  });
  logAct_('Asset updated', {tracker: 'Assets',
    name: String(sh.getRange(q.row, head.indexOf('Name') + 1).getValue() || ''),
    note: Object.keys(q.fields || {}).map(k => k + ': ' + q.fields[k]).join(', ').slice(0, 180)});
  return { ok: true };
}

/* ========================= stores & transfers ============================ */

function moveStore_(q) {
  // q: {tracker, rows:[sheetRow,...], toStore}
  const sh = ss_().getSheetByName(q.tracker);
  if (!sh) return { ok: false, error: 'No tab: ' + q.tracker };
  const head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(String);
  const cLoc = head.indexOf('Location') + 1;
  if (!cLoc) return { ok: false, error: 'No Location column in ' + q.tracker };
  (q.rows || []).forEach(r => sh.getRange(r, cLoc).setValue(q.toStore || ''));
  logAct_('Stock transferred', {tracker: q.tracker, name: (q.rows || []).length + ' item(s)',
    qty: (q.rows || []).length, note: 'Moved to ' + q.toStore});
  return { ok: true, moved: (q.rows || []).length };
}

function storeAdd_(q) {
  const sh = ss_().getSheetByName('Stores');
  if (!sh) return { ok: false, error: 'Stores tab missing — run migrate()' };
  sh.appendRow([q.tracker || '', q.store || '']);
  logAct_('Store added', {tracker: q.tracker, name: q.store});
  return { ok: true };
}

function storeRemove_(q) {
  // q: {row}
  const sh = ss_().getSheetByName('Stores');
  if (!sh) return { ok: false, error: 'Stores tab missing' };
  const name = sh.getRange(q.row, 2).getValue();
  sh.deleteRow(q.row);
  logAct_('Store removed', {name: String(name || '')});
  return { ok: true };
}

/* ============================ users & auth =============================== */

const USER_HEADERS = ['Username','Password','Role','DisplayName','Active'];

function hash_(username, password) {
  const raw = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,
    String(username).toLowerCase() + ':' + String(password), Utilities.Charset.UTF_8);
  return raw.map(b => ((b & 0xFF) + 0x100).toString(16).slice(1)).join('');
}

function usersSheet_() {
  const sh = ss_().getSheetByName('Users');
  if (!sh) throw 'Users tab missing — run migrate()';
  return sh;
}

function login_(q) {
  const u = String(q.username || '').trim().toLowerCase();
  const p = String(q.password || '');
  if (!u || !p) return { ok: false, error: 'Enter username and password' };
  const sh = usersSheet_();
  const vals = sh.getDataRange().getValues();
  for (let r = 1; r < vals.length; r++) {
    const [un, stored, role, name, active] = vals[r];
    if (String(un).trim().toLowerCase() !== u) continue;
    if (String(active).toLowerCase() === 'no') return { ok: false, error: 'Account disabled' };
    const s = String(stored);
    const matchHash = /^[0-9a-f]{64}$/.test(s) && s === hash_(u, p);
    const matchPlain = !/^[0-9a-f]{64}$/.test(s) && s === p;
    if (matchHash || matchPlain) {
      if (matchPlain) sh.getRange(r + 1, 2).setValue(hash_(u, p));  // upgrade to hash
      const token = Utilities.getUuid();
      saveToken_(token, { u: u, role: String(role || 'common').toLowerCase(),
                          name: String(name || u), exp: Date.now() + 7 * 86400000 });
      return { ok: true, token: token, role: String(role || 'common').toLowerCase(),
               displayName: String(name || u), username: u };
    }
    return { ok: false, error: 'Wrong password' };
  }
  return { ok: false, error: 'Unknown username' };
}

function changePassword_(q) {
  const s = q._session;
  const sh = usersSheet_();
  const vals = sh.getDataRange().getValues();
  for (let r = 1; r < vals.length; r++) {
    if (String(vals[r][0]).trim().toLowerCase() !== s.u) continue;
    const stored = String(vals[r][1]);
    const okOld = (/^[0-9a-f]{64}$/.test(stored) && stored === hash_(s.u, q.oldPassword)) ||
                  (!/^[0-9a-f]{64}$/.test(stored) && stored === String(q.oldPassword));
    if (!okOld) return { ok: false, error: 'Current password is wrong' };
    if (String(q.newPassword || '').length < 6)
      return { ok: false, error: 'New password must be at least 6 characters' };
    sh.getRange(r + 1, 2).setValue(hash_(s.u, q.newPassword));
    return { ok: true };
  }
  return { ok: false, error: 'User not found' };
}

function saveToken_(token, data) {
  const props = PropertiesService.getScriptProperties();
  let all = {};
  try { all = JSON.parse(props.getProperty('tokens') || '{}'); } catch (e) {}
  const now = Date.now();
  Object.keys(all).forEach(t => { if (all[t].exp < now) delete all[t]; });
  all[token] = data;
  props.setProperty('tokens', JSON.stringify(all));
}

function auth_(token) {
  if (!token) return null;
  let all = {};
  try { all = JSON.parse(
    PropertiesService.getScriptProperties().getProperty('tokens') || '{}'); } catch (e) {}
  const s = all[token];
  if (!s || s.exp < Date.now()) return null;
  return s;
}

/* ======================= daily alert + escalation ========================= */

function setupTriggers() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('dailyStockCheck').timeBased().everyDays(1).atHour(8).create();
  ScriptApp.newTrigger('escalationCheck').timeBased().everyHours(4).create();
  ScriptApp.newTrigger('dailyActivityEmail').timeBased().everyDays(1).atHour(0).create();
}

function dailyActivityEmail() {
  const email = setting_('activity_email', setting_('alert_email', ''));
  if (!email) return;
  const appName = setting_('app_name', 'Bollin Clinic Inventory');
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const yday = new Date(today); yday.setDate(yday.getDate() - 1);
  const rows = readTab_('Transactions').filter(t => {
    const d = t.Timestamp ? new Date(t.Timestamp) : null;
    return d && d >= yday && d < today;
  });
  const dayLabel = Utilities.formatDate(yday, Session.getScriptTimeZone(), 'EEEE d MMMM yyyy');
  if (!rows.length) {
    MailApp.sendEmail({ to: email, subject: appName + ' — activity log ' + dayLabel,
      htmlBody: '<p>No activity was recorded on ' + dayLabel + '.</p>' });
    return;
  }
  const cell = 'border:1px solid #C9D6D2;padding:4px 7px;font-size:12px;';
  let body = '<h3 style="color:#2B6168">' + appName + ' — activity for ' + dayLabel + '</h3>' +
    '<p>' + rows.length + ' event(s)</p>' +
    '<table style="border-collapse:collapse"><tr>' +
    ['Time', 'Activity', 'Tracker', 'Item', 'Code', 'Qty', 'By', 'Details'].map(x =>
      '<th style="' + cell + 'background:#2B6168;color:#fff">' + x + '</th>').join('') + '</tr>';
  rows.forEach(t => {
    const act = t.Activity || (t.Direction === 'in' ? 'Stock in' : t.Direction === 'out' ? 'Stock out' : '');
    body += '<tr>' + [
      Utilities.formatDate(new Date(t.Timestamp), Session.getScriptTimeZone(), 'HH:mm'),
      act, t.Tracker || '', t.Name || '', t.Code || '', t.Qty || '', t.By || '', t.Note || ''
    ].map(x => '<td style="' + cell + '">' + x + '</td>').join('') + '</tr>';
  });
  body += '</table>';
  MailApp.sendEmail({ to: email, subject: appName + ' — activity log ' + dayLabel +
    ' (' + rows.length + ' events)', htmlBody: body });
}

/** Run from the editor to wipe ONLY the implant test data (keeps the header row). */
function resetImplantsTestData() {
  const sh = ss_().getSheetByName('Implants');
  if (!sh) return 'No Implants tab';
  const n = sh.getLastRow();
  if (n > 1) sh.getRange(2, 1, n - 1, sh.getLastColumn()).clearContent();
  return 'Cleared ' + Math.max(0, n - 1) + ' implant row(s)';
}

function dailyStockCheck() {
  const email = setting_('alert_email', '');
  if (!email) return;                              // not configured yet
  const expDays = Number(setting_('expiry_days', 90));
  const appName = setting_('app_name', 'Bollin Clinic Inventory');
  const alertsSh = ss_().getSheetByName('Alerts');
  const existing = readTab_('Alerts')
    .filter(a => a.Status !== 'Acknowledged')
    .map(a => a.Type + '|' + a.Tracker + '|' + a.Code);

  const low = [], out = [], exp = [];
  const today = new Date(); today.setHours(0, 0, 0, 0);

  ITEM_TABS.filter(t => t !== 'Instruments').forEach(t => {
    readTab_(t).forEach(it => {
      if (String(it.Obsolete || '').toLowerCase() === 'yes') return;   // dead stock: no alerts
      const qty = Number(it.Qty) || 0, ro = Number(it.ReorderLevel) || 0;
      if (qty === 0) out.push({ t: t, it: it });
      else if (ro > 0 && qty <= ro) low.push({ t: t, it: it });
      if (it.Expiry) {
        const d = Math.round((new Date(it.Expiry) - today) / 86400000);
        if (d <= expDays) exp.push({ t: t, it: it, d: d });
      }
    });
  });

  const fresh = [];
  function record(type, t, it, detail) {
    const key = type + '|' + t + '|' + (it.Code || it.Name);
    if (existing.indexOf(key) >= 0) return;        // already alerted, not yet acked
    alertsSh.appendRow([new Date(), type, t, it.Code || '', it.Name, detail, 'Sent', '', '']);
    fresh.push({ row: alertsSh.getLastRow(), type: type, name: it.Name, detail: detail });
  }
  out.forEach(x => record('Out of stock', x.t, x.it, 'Qty 0, reorder level ' + x.it.ReorderLevel));
  low.forEach(x => record('Low stock', x.t, x.it, 'Qty ' + x.it.Qty + ', reorder level ' + x.it.ReorderLevel));
  exp.forEach(x => record('Expiry', x.t, x.it,
    x.d < 0 ? 'EXPIRED ' + (-x.d) + ' days ago' : 'Expires in ' + x.d + ' days'));

  if (!fresh.length) return;
  const url = ScriptApp.getService().getUrl();
  let body = '<h3>' + appName + ' — daily stock alerts</h3><ul>';
  fresh.forEach(f => {
    body += '<li><b>' + f.type + ':</b> ' + f.name + ' — ' + f.detail +
            ' &nbsp;<a href="' + url + '?ack=' + f.row + '">Acknowledge</a></li>';
  });
  body += '</ul><p>Unacknowledged alerts escalate after ' +
          setting_('ack_hours', 48) + ' hours.</p>';
  MailApp.sendEmail({ to: email, subject: appName + ': ' + fresh.length + ' stock alert(s)',
                      htmlBody: body });
}

function escalationCheck() {
  const escEmail = setting_('escalation_email', '');
  if (!escEmail) return;
  const hours = Number(setting_('ack_hours', 48));
  const appName = setting_('app_name', 'Bollin Clinic Inventory');
  const sh = ss_().getSheetByName('Alerts');
  const rows = readTab_('Alerts');
  const overdue = rows.filter(a =>
    a.Status === 'Sent' &&
    (new Date() - new Date(a.Timestamp)) / 3600000 >= hours);
  if (!overdue.length) return;

  let body = '<h3>' + appName + ' — ESCALATION</h3>' +
    '<p>The following alerts were not acknowledged within ' + hours + ' hours:</p><ul>';
  overdue.forEach(a => {
    body += '<li><b>' + a.Type + ':</b> ' + a.Item + ' — ' + a.Detail +
            ' (raised ' + Utilities.formatDate(new Date(a.Timestamp),
              Session.getScriptTimeZone(), 'dd/MM/yyyy HH:mm') + ')</li>';
    sh.getRange(a._row, 7).setValue('Escalated');
  });
  body += '</ul>';
  MailApp.sendEmail({ to: escEmail, subject: appName + ': ESCALATION — ' +
                      overdue.length + ' unacknowledged alert(s)', htmlBody: body });
}
