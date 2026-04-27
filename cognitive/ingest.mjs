// SENSORY INGEST — write a frame into episodic_memory + update cognitive_map.
// This is the 'thalamic relay in reverse' — sensory data arrives, gets
// distributed to the appropriate cortical regions.
import Database from 'better-sqlite3';
import { encode as geohash } from './geohash.mjs';
import { assignSubArea } from './sub_area.mjs';

export function ingestFrame(db, frame) {
  // Required: ts. Everything else nullable.
  const ts = frame.ts || Date.now();
  const d = new Date(ts);
  const iso_ts = d.toISOString();
  const hour_of_day = d.getUTCHours();
  const day_of_week = d.getUTCDay();
  const month_of_year = d.getUTCMonth() + 1;
  // Lighting state — derive from time-of-day + scene confidence + object count.
  // V4 color-constancy analog. Helps cluster the same place across day/night.
  const lighting_state = (() => {
    const h = hour_of_day;
    const isDay = h >= 8 && h < 18;
    const isNight = h >= 22 || h < 5;
    const isLowConf = (frame.scene_confidence ?? 1.0) < 0.6;
    const objCount = (frame.objects || []).length;
    const fewObjs = objCount < 3;
    if (isNight && (isLowConf || fewObjs)) return 'dark';
    if (isNight) return 'dim';
    if (isDay && !isLowConf) return 'bright';
    return 'typical';
  })();
  const geohash7 = (frame.lat != null && frame.lon != null) ? geohash(frame.lat, frame.lon, 7) : null;
  const geohash5 = (frame.lat != null && frame.lon != null) ? geohash(frame.lat, frame.lon, 5) : null;

  // 1. Insert into episodic_memory (Hippocampus)
  const result = db.prepare(`INSERT INTO episodic_memory
    (ts, iso_ts, lat, lon, gps_accuracy, geohash7, geohash5,
     hour_of_day, day_of_week, month_of_year,
     scene, scene_confidence, objects, ocr_text, featureprint, thumb_path,
     transcript, speech_tone, lighting_state,
     source, agent_id, device_id)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      ts, iso_ts, frame.lat || null, frame.lon || null, frame.gps_accuracy || null,
      geohash7, geohash5, hour_of_day, day_of_week, month_of_year,
      frame.scene || null, frame.scene_confidence || null,
      frame.objects ? JSON.stringify(frame.objects) : null,
      frame.ocr_text || null,
      frame.featureprint ? Buffer.from(frame.featureprint) : null,
      frame.thumb_path || null,
      frame.transcript || null, frame.speech_tone || null, lighting_state,
      frame.source || 'unknown', frame.agent_id || null, frame.device_id || null
    );

  // 1.5 Assign sub_area within this geohash7 (Hippocampal sub-area clustering)
  if (geohash7) {
    const objs = frame.objects || null;
    const sa_id = assignSubArea(db, geohash7, { scene: frame.scene, objects: objs }, ts);
    db.prepare('UPDATE episodic_memory SET sub_area_id = ? WHERE id = ?').run(sa_id, result.lastInsertRowid);
  }

  // 2. Update cognitive_map (Entorhinal grid cells) if we have GPS
  if (geohash7) {
    const existing = db.prepare('SELECT * FROM cognitive_map WHERE geohash7 = ?').get(geohash7);
    if (existing) {
      const newCount = existing.visit_count + 1;
      // Cluster frames into distinct visits (frames within 2h = same visit)
      // before computing the gap. Otherwise consecutive frames within the
      // same visit make every place look 'multiple-daily'.
      const allFrames = db.prepare('SELECT ts FROM episodic_memory WHERE geohash7 = ? ORDER BY ts ASC').all(geohash7);
      const VISIT_GAP_MS = 2 * 3600 * 1000;
      const visits = [];
      for (const f of allFrames) {
        if (visits.length && f.ts - visits[visits.length-1].end <= VISIT_GAP_MS) {
          visits[visits.length-1].end = f.ts;
        } else {
          visits.push({ start: f.ts, end: f.ts });
        }
      }
      const gaps = [];
      for (let i = 1; i < visits.length; i++) gaps.push(visits[i].start - visits[i-1].end);
      const median_visit_gap_days = gaps.length ?
        (gaps.sort((a,b)=>a-b)[Math.floor(gaps.length/2)] / 86400000) : null;
      // Update visit_count to be distinct visits, not raw frame count
      const distinctVisits = visits.length;
      db.prepare(`UPDATE cognitive_map SET last_visit_ts=?, visit_count=?, median_visit_gap_days=?, updated_ts=?
        WHERE geohash7 = ?`).run(ts, distinctVisits, median_visit_gap_days, Date.now(), geohash7);
    } else {
      db.prepare(`INSERT INTO cognitive_map
        (geohash7, first_visit_ts, last_visit_ts, visit_count, updated_ts)
        VALUES (?,?,?,?,?)`).run(geohash7, ts, ts, 1, Date.now());
    }
  }

  return { episodic_id: result.lastInsertRowid, geohash7, geohash5 };
}
