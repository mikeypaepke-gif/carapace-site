// AUDITORY CORTEX — chat + voice STT into episodic_memory.
// Brain analog: A1 (primary auditory) → Wernicke's (language) → hippocampus.
// Same temporal/spatial tagging as vision; lets the system recall WHAT
// you talked about WHERE and WHEN.
import Database from 'better-sqlite3';
import { encode as geohash } from './geohash.mjs';
import { assignSubArea } from './sub_area.mjs';

export function ingestUtterance(db, utt) {
  const ts = utt.ts || Date.now();
  const d = new Date(ts);
  const geohash7 = (utt.lat != null && utt.lon != null) ? geohash(utt.lat, utt.lon, 7) : null;
  const geohash5 = (utt.lat != null && utt.lon != null) ? geohash(utt.lat, utt.lon, 5) : null;
  const lighting_state = (() => {
    const h = d.getUTCHours();
    if ((h >= 22 || h < 5)) return 'dim';
    if (h >= 8 && h < 18) return 'bright';
    return 'typical';
  })();

  // Insert into episodic_memory with transcript filled in
  const result = db.prepare(`INSERT INTO episodic_memory
    (ts, iso_ts, lat, lon, gps_accuracy, geohash7, geohash5,
     hour_of_day, day_of_week, month_of_year,
     scene, scene_confidence, objects, ocr_text, featureprint, thumb_path,
     transcript, speech_tone, lighting_state,
     source, agent_id, device_id, sub_area_id)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      ts, d.toISOString(), utt.lat || null, utt.lon || null, utt.gps_accuracy || null,
      geohash7, geohash5, d.getUTCHours(), d.getUTCDay(), d.getUTCMonth() + 1,
      null, null, null, null, null, null,
      utt.transcript || null, utt.speech_tone || null, lighting_state,
      utt.source || 'chat', utt.agent_id || null, utt.device_id || null, null
    );

  // Try to inherit sub_area from a recent vision frame at the same geohash7
  // (within last 5 min) — voice/chat happens AT a place that vision already tagged.
  if (geohash7) {
    const recentVision = db.prepare(`SELECT sub_area_id FROM episodic_memory
      WHERE geohash7 = ? AND scene IS NOT NULL AND ts > ? AND id < ?
      ORDER BY ts DESC LIMIT 1`).get(geohash7, ts - 5*60*1000, result.lastInsertRowid);
    if (recentVision?.sub_area_id) {
      db.prepare('UPDATE episodic_memory SET sub_area_id = ? WHERE id = ?').run(recentVision.sub_area_id, result.lastInsertRowid);
    }
  }
  return { episodic_id: result.lastInsertRowid, geohash7 };
}
