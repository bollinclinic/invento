#!/bin/bash
# Regenerates index_STAGING.html from index.html so the two files can never drift
# apart on logic — only the intentional staging differences (title, badge, CSS,
# CONFIG) are applied on top. Run this after any edit to index.html, before
# deploy-staging.sh.
set -e
cd "$(dirname "$0")"

PROD_URL="https://ozkragagmtdjjlkvygjc.supabase.co"
PROD_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im96a3JhZ2FnbXRkampsa3Z5Z2pjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNTM5NTMsImV4cCI6MjEwMjYyOTk1M30.16yVOfJqDoyY7KYXnPn3KocwToCwWEYDRv8PGo-52nA"
STAGING_URL="https://ozlskwtbgblfmqjgcrmf.supabase.co"
STAGING_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im96bHNrd3RiZ2JsZm1xamdjcm1mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNTQyNzEsImV4cCI6MjEwMjYzMDI3MX0.jTRbcxqPHoygje8zMXEZk-TaxJKv3m-y6-ZtY9wS0JA"

node -e "
const fs = require('fs');
let html = fs.readFileSync('index.html', 'utf8');
html = html.replace('<title>Bollin Clinic — Inventory</title>', '<title>[STAGING] Bollin Clinic — Inventory</title>');
html = html.replace(
  '<a class=\"brand\" href=\"#dashboard\" onclick=\"goHome(event)\" title=\"Bollin Clinic Stock Manager — home\">\n      <img src=\"logo.png\" alt=\"Bollin Clinic Stock Manager\"></a>',
  '<a class=\"brand\" href=\"#dashboard\" onclick=\"goHome(event)\" title=\"Bollin Clinic Stock Manager — home\">\n      <img src=\"logo.png\" alt=\"Bollin Clinic Stock Manager\"></a>\n    <span class=\"stagingtag\" title=\"This is the staging test site — not live clinic data\">STAGING</span>'
);
html = html.replace('<style>\n  :root{',
  '<style>\n  body::before{content:\"\";position:fixed;top:0;left:0;right:0;height:4px;\n      background:repeating-linear-gradient(45deg,#B08A3E,#B08A3E 10px,#8A6E2E 10px,#8A6E2E 20px);z-index:200}\n  .stagingtag{margin-left:10px;padding:4px 11px;border-radius:99px;font-family:\'Inter\',system-ui,sans-serif;\n      font-size:11px;font-weight:800;letter-spacing:1.5px;color:#7A5A14;background:#F3E7C6;\n      border:1px solid #E0CC97;white-space:nowrap}\n  @media (max-width:760px){ .stagingtag{font-size:9.5px;padding:3px 8px;letter-spacing:1px} }\n  :root{');
html = html.replace('$PROD_URL', '$STAGING_URL').replace('$PROD_KEY', '$STAGING_KEY');
html = html.replace('CONFIG — Supabase project this build talks to.', 'CONFIG — STAGING BUILD — points at the invento-staging Supabase project.');
fs.writeFileSync('index_STAGING.html', html);
console.log('index_STAGING.html regenerated from index.html');
"
