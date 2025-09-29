/**
 * Upserts a knowledge base entry through the Supabase REST endpoint using the
 * `knowledge_base_question_key` constraint that normalizes the question text.
 *
 * @param {Object} params
 * @param {string} params.supabaseUrl - The Supabase project URL.
 * @param {string} params.serviceKey - The service role key used for the request.
 * @param {{ question: string, answer: string, metadata?: Record<string, any> }} params.entry
 *   The entry that should be inserted/updated.
 */
export async function upsertKnowledgeBase({ supabaseUrl, serviceKey, entry }) {
  if (!supabaseUrl) {
    throw new Error('`supabaseUrl` is required');
  }
  if (!serviceKey) {
    throw new Error('`serviceKey` is required');
  }
  if (!entry || typeof entry.question !== 'string' || typeof entry.answer !== 'string') {
    throw new Error('`entry` with `question` and `answer` fields is required');
  }

  const url = new URL('/rest/v1/knowledge_base', supabaseUrl);
  url.searchParams.set('on_conflict', 'knowledge_base_question_key');

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates,return=representation',
    },
    body: JSON.stringify({
      question: entry.question,
      answer: entry.answer,
      metadata: entry.metadata ?? {},
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `Supabase knowledge_base upsert failed (${response.status} ${response.statusText}): ${errorText}`,
    );
  }

  return response.json();
}

/**
 * Helper that can be used by consumers (such as n8n expressions) to mirror the
 * database normalization behaviour. Keeping the logic in sync with the
 * generated column prevents accidental duplicates when comparing input values.
 *
 * @param {string} question - Question to normalize.
 * @returns {string}
 */
export function normalizeQuestion(question) {
  if (typeof question !== 'string') {
    throw new TypeError('`question` must be a string');
  }

  return question.trim().toLowerCase();
}
