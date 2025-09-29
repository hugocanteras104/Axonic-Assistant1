import test from 'node:test';
import assert from 'node:assert/strict';
import { upsertKnowledgeBase, normalizeQuestion } from '../scripts/upsertKnowledgeBase.js';

test('normalizeQuestion mirrors the database normalization logic', () => {
  assert.equal(normalizeQuestion('  HELLO World '), 'hello world');
});

test('upsertKnowledgeBase targets the generated-column constraint', async () => {
  let capturedUrl;
  let capturedInit;

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    capturedUrl = url;
    capturedInit = init;
    return new Response(JSON.stringify([{ id: '123' }]), {
      status: 201,
      headers: { 'content-type': 'application/json' },
    });
  };

  try {
    await upsertKnowledgeBase({
      supabaseUrl: 'https://project.supabase.co',
      serviceKey: 'service-key',
      entry: { question: 'How Are You?', answer: 'Great!' },
    });

    assert.ok(capturedUrl, 'fetch should be called');
    const url = new URL(capturedUrl);
    assert.equal(url.pathname, '/rest/v1/knowledge_base');
    assert.equal(
      url.searchParams.get('on_conflict'),
      'knowledge_base_question_key',
      'Upserts must reference the generated-column constraint',
    );

    assert.equal(capturedInit.method, 'POST');
    assert.equal(
      capturedInit.headers.Prefer,
      'resolution=merge-duplicates,return=representation',
      'Prefer header must merge duplicates to trigger the constraint',
    );

    const body = JSON.parse(capturedInit.body);
    assert.deepEqual(body, {
      question: 'How Are You?',
      answer: 'Great!',
      metadata: {},
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});
