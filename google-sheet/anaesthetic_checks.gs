/**
 * ANAESTHETIC CHECKS  ->  a tab called "Anaesthetic Checks" in the monitoring Google Sheet.
 *
 * The Stock Manager app sends each anaesthetic check to the same link as the temperature,
 * fridge, fluid warmer, hand hygiene and cleaning checks, marked  type: "anaesthetic".
 * The existing script does not know that type, so this block has to be added to it.
 *
 * HOW TO ADD IT (once, about two minutes):
 *   1. Open the monitoring Google Sheet  ->  Extensions  ->  Apps Script.
 *   2. Find the line that starts   function doPost(e)   and change ONLY the name to
 *      doPostOther   so it reads   function doPostOther(e)
 *   3. Paste everything in this file at the very bottom of the script. Press Save.
 *   4. Deploy  ->  Manage deployments  ->  the pencil (Edit)  ->  Version: "New version"
 *      ->  Deploy.   Do NOT choose "New deployment": the link must stay the same.
 *
 * Nothing else in the script changes: every other check still goes through the old code.
 * The tab and its heading row are made automatically the first time a check arrives.
 */

// Only needed if step 1 was NOT how you opened the script (a stand-alone script):
// put the Sheet's ID here (the long code in the Sheet's web address). Otherwise leave it empty.
var ANAES_SHEET_ID = '';
var ANAES_TAB = 'Anaesthetic Checks';

var ANAES_COLUMNS = [
  ['Received',                     function (d) { return new Date(); }],
  ['Date',                         'date'],
  ['Day',                          'day'],
  ['Time',                         'time'],
  ['Theatre',                      'theatre'],
  ['Check',                        'phase'],
  ['Result',                       function (d) { return d.status === 'fail' ? 'ACTION NEEDED' : 'OK'; }],
  ['Checked by',                   'checkedBy'],
  ['Machine test',                 'machineTest'],
  ['Escalated to',                 'escalatedTo'],
  ['Circuit last changed',         'circuitDate'],
  ['Circuit age found (days)',     'circuitAgeDays'],
  ['Circuit changed today by',     'circuitChangedBy'],
  ['Water trap last changed',      'waterTrapDate'],
  ['Water trap age found (days)',  'waterTrapAgeDays'],
  ['Water trap changed today by',  'waterTrapChangedBy'],
  ['Soda lime colour',             'sodaLimeColour'],
  ['Soda lime last changed',       'sodaLimeDate'],
  ['Soda lime changed today by',   'sodaLimeChangedBy'],
  ['Fluid & medication cupboard',  'cupboardStocked'],
  ['Controlled drugs checked',     'controlledDrugsChecked'],
  ['CD practitioner 1',            'cdPractitioner1'],
  ['CD practitioner 2',            'cdPractitioner2'],
  ['Video laryngoscope',           'videoLaryngoscope'],
  ['All devices ready',            'devicesReady'],
  ['End of list: done',            'endDone'],
  ['End of list: not done',        'endNotDone'],
  ['Action needed',                'actionNeeded'],
  ['Notes',                        'notes'],
  ['Signed in as',                 'sentBy']
];

function doPost(e) {
  var data = null;
  try { data = JSON.parse(e.postData.contents); } catch (err) { data = null; }
  if (data && data.type === 'anaesthetic') return anaestheticCheck_(data);
  return doPostOther(e);          // every other check: the existing code, unchanged
}

function anaestheticCheck_(d) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
    var ss = SpreadsheetApp.getActiveSpreadsheet() || (ANAES_SHEET_ID ? SpreadsheetApp.openById(ANAES_SHEET_ID) : null);
    if (!ss) return anaesReply_({ ok: false, error: 'No spreadsheet: fill in ANAES_SHEET_ID' });
    var sh = ss.getSheetByName(ANAES_TAB);
    if (!sh) {
      sh = ss.insertSheet(ANAES_TAB);
      sh.appendRow(ANAES_COLUMNS.map(function (c) { return c[0]; }));
      sh.getRange(1, 1, 1, ANAES_COLUMNS.length).setFontWeight('bold').setBackground('#2B6168').setFontColor('#FFFFFF');
      sh.setFrozenRows(1);
    }
    var row = ANAES_COLUMNS.map(function (c) {
      var v = (typeof c[1] === 'function') ? c[1](d) : d[c[1]];
      if (v === true) return 'Yes';
      if (v === false) return 'No';
      if (v === null || v === undefined) return '';
      if (Object.prototype.toString.call(v) === '[object Array]') return v.join('; ');
      return v;
    });
    sh.appendRow(row);
    var n = sh.getLastRow();
    if (d.status === 'fail') sh.getRange(n, 1, 1, ANAES_COLUMNS.length).setBackground('#FCE9E7');
    return anaesReply_({ ok: true, type: 'anaesthetic', tab: ANAES_TAB, row: n });
  } catch (err) {
    return anaesReply_({ ok: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch (err2) {}
  }
}

function anaesReply_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
