import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const migration = fs.readFileSync(
  new URL('../supabase/migrations/20260920_safe_application_workflow.sql', import.meta.url),
  'utf8',
);

const inlineScripts = [...html.matchAll(/<script(?: [^>]*)?>([\s\S]*?)<\/script>/g)];
assert.ok(inlineScripts.length, 'index.html must contain an inline application script');
new Function(inlineScripts.at(-1)[1]);

for (const required of [
  'LISTING_STATES',
  'DECISION_STATES',
  'APPLICATION_STATES',
  'OUTREACH_STATES',
  'grantApproval',
  'revokeApproval',
  'submission_uncertain',
  'Approval alone performs no external action',
]) {
  assert.ok(html.includes(required), `UI contract is missing ${required}`);
}

assert.ok(!/service[_-]?role[^\n]{0,80}(?:key|eyJ)/i.test(html), 'browser code must not contain a service-role credential');

for (const table of [
  'application_packages',
  'application_approvals',
  'submission_intents',
  'application_evidence',
  'candidate_truth_claims',
  'reconciliation_items',
  'application_communications',
]) {
  assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
}

assert.match(migration, /idempotency_key text not null unique/i);
assert.match(migration, /Finalized application packages are immutable/i);
assert.match(migration, /grant update \(approval_state, revoked_at\)/i);
assert.doesNotMatch(migration, /grant all on table [^;]+ to (?:anon|authenticated)/i);

console.log('Static Career Cockpit contract: OK');
