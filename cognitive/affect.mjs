// AMYGDALA — affect tags. Detects user corrections + satisfaction signals,
// writes them as priors for future turns at the same place.
//
// Brain analog: amygdala tags memories with emotional valence.
// Ours: explicit corrections override schemas; satisfaction reinforces.
import Database from 'better-sqlite3';
import { encode as geohash } from './geohash.mjs';

// Heuristic detection — works without LLM, deterministic, fast.
const CORRECTION_PATTERNS = [
  /\b(no|nope|not|wrong|incorrect|actually|thats not|that..s not)\b.{0,80}/i,
  /\b(it..s|its)\s+(actually|really|a|an|my|the)\s+\w+/i,
  /\b(?:i meant|to be exact|correction)\b/i,
  /\b(?:you got that wrong|you..re wrong|that..s incorrect)\b/i,
];
const SATISFACTION_PATTERNS = [
  /\b(?:thanks|thank you|thx|perfect|exactly|got it|correct|right|nailed it)\b/i,
  /\b(?:that..s right|spot on|nice|appreciate)\b/i,
];
const NEGATION_PHRASES = ['no it isn', 'no its not', 'no that..s', 'no i didn'];

export function detectAffect(userText, prevAssistantText) {
  const t = userText.toLowerCase();
  // Correction with explicit reference to prev assistant text
  if (CORRECTION_PATTERNS.some(re => re.test(t))) {
    // Try to extract the corrected version (simple heuristic)
    const m = t.match(/(?:it..?s|its|that..?s|thats)\s+(?:actually\s+|really\s+)?([a-z][a-z\s\-]{2,40})\b/);
    const corrected = m?.[1]?.trim() || null;
    return { type: 'user_correction', valence: -0.5, corrected_to: corrected };
  }
  if (SATISFACTION_PATTERNS.some(re => re.test(t))) {
    return { type: 'explicit_thanks', valence: 0.6 };
  }
  return null;
}

export function ingestAffect(db, signal) {
  const ts = signal.ts || Date.now();
  const gh7 = (signal.lat != null && signal.lon != null) ? geohash(signal.lat, signal.lon, 7) : null;
  const result = db.prepare(`INSERT INTO affect_tags
    (ts, episodic_id, geohash7, schema_id, valence, signal_type, signal_text,
     was_response_text, corrected_to_text)
    VALUES (?,?,?,?,?,?,?,?,?)`).run(
      ts, signal.episodic_id || null, gh7, signal.schema_id || null,
      signal.valence, signal.signal_type, signal.signal_text || null,
      signal.was_response_text || null, signal.corrected_to_text || null
    );
  return { affect_id: result.lastInsertRowid };
}
