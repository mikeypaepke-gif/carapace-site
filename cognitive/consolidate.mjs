// CONSOLIDATION (Default Mode Network) — runs as a cron, slow path.
// Takes raw episodic_memory and derives place_schemas, routine_patterns,
// updates cognitive_map semantic labels, prunes redundant frames.
//
// This is what 'sleep' does for the brain — it never happens during a
// conversation turn. Per-turn cost is unaffected.
import Database from 'better-sqlite3';

function timeBucket(hour) {
  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 17) return 'afternoon';
  if (hour >= 17 && hour < 22) return 'evening';
  return 'night';
}
function dayBucket(dow) {
  return (dow === 0 || dow === 6) ? 'weekend' : 'weekday';
}

// ─── PLACE SCHEMAS ──────────────────────────────────────────────────
// For each (geohash7, time_bucket, day_bucket) group with ≥3 frames,
// derive a schema: dominant scene, top objects, recurring OCR.
export function extractPlaceSchemas(db) {
  const t0 = Date.now();
  let changed = 0, processed = 0;

  // Group by (sub_area_id, hour_of_day, day_of_week) — sub-area-scoped
  // schemas. Without this, a living_room schema at home would inherit
  // the kitchen objects because they share a geohash7.
  const groups = db.prepare(`
    SELECT geohash7, sub_area_id, hour_of_day, day_of_week, COUNT(*) as cnt
    FROM episodic_memory
    WHERE geohash7 IS NOT NULL AND sub_area_id IS NOT NULL
    GROUP BY geohash7, sub_area_id, hour_of_day, day_of_week
  `).all();

  // Collapse hour/dow into broader buckets per sub_area
  const bucketed = new Map();
  for (const g of groups) {
    const tb = (g.hour_of_day >= 5 && g.hour_of_day < 12) ? 'morning'
            : (g.hour_of_day >= 12 && g.hour_of_day < 17) ? 'afternoon'
            : (g.hour_of_day >= 17 && g.hour_of_day < 22) ? 'evening' : 'night';
    const dbk = (g.day_of_week === 0 || g.day_of_week === 6) ? 'weekend' : 'weekday';
    const key = g.geohash7 + '|' + g.sub_area_id + '|' + tb + '|' + dbk;
    if (!bucketed.has(key)) bucketed.set(key, { geohash7: g.geohash7, sub_area_id: g.sub_area_id, tb, dbk });
  }

  for (const [key, info] of bucketed) {
    processed++;
    const tbHours = { morning: '5-12', afternoon: '12-17', evening: '17-22', night: '22-5' };
    const dowFilter = info.dbk === 'weekend' ? 'day_of_week IN (0,6)' : 'day_of_week NOT IN (0,6)';
    const hourFilter = info.tb === 'night'
      ? '(hour_of_day >= 22 OR hour_of_day < 5)'
      : info.tb === 'morning' ? 'hour_of_day >= 5 AND hour_of_day < 12'
      : info.tb === 'afternoon' ? 'hour_of_day >= 12 AND hour_of_day < 17'
      : 'hour_of_day >= 17 AND hour_of_day < 22';

    const frames = db.prepare(`SELECT id, scene, objects, ocr_text, ts FROM episodic_memory
      WHERE geohash7 = ? AND sub_area_id = ? AND ${dowFilter} AND ${hourFilter}
      ORDER BY ts DESC LIMIT 100`).all(info.geohash7, info.sub_area_id);
    if (frames.length < 3) continue;

    const sceneCounts = {};
    for (const f of frames) if (f.scene) sceneCounts[f.scene] = (sceneCounts[f.scene] || 0) + 1;
    const scene_label = Object.entries(sceneCounts).sort((a,b) => b[1]-a[1])[0]?.[0] || null;

    const objCounts = {};
    for (const f of frames) {
      if (!f.objects) continue;
      try { for (const o of JSON.parse(f.objects)) objCounts[o] = (objCounts[o] || 0) + 1; } catch {}
    }
    const common_objects = Object.entries(objCounts).sort((a,b) => b[1]-a[1])
      .slice(0, 10).map(([obj, cnt]) => ({ obj, freq: +(cnt/frames.length).toFixed(2) }));

    const ocrCounts = {};
    for (const f of frames) {
      if (!f.ocr_text) continue;
      const phrases = f.ocr_text.split(/[\n.]/).map(s => s.trim()).filter(s => s.length > 3);
      for (const p of phrases) ocrCounts[p] = (ocrCounts[p] || 0) + 1;
    }
    const common_ocr = Object.entries(ocrCounts).filter(([_, c]) => c > 1).slice(0, 5).map(([p]) => p);
    const reps = frames.slice(0, 5).map(f => f.id);
    const confidence = Math.min(0.95, Math.log(frames.length + 1) / 5);

    const existing = db.prepare(
      'SELECT id FROM place_schemas WHERE geohash7=? AND sub_area_id=? AND time_bucket=? AND day_bucket=?'
    ).get(info.geohash7, info.sub_area_id, info.tb, info.dbk);
    if (existing) {
      db.prepare(`UPDATE place_schemas SET scene_label=?, common_objects=?, common_ocr_terms=?,
        representative_episodic_ids=?, source_frame_count=?, confidence=?, last_updated_ts=?
        WHERE id=?`).run(scene_label, JSON.stringify(common_objects), JSON.stringify(common_ocr),
        JSON.stringify(reps), frames.length, confidence, Date.now(), existing.id);
    } else {
      db.prepare(`INSERT INTO place_schemas
        (geohash7, sub_area_id, time_bucket, day_bucket, scene_label, common_objects, common_ocr_terms,
         representative_episodic_ids, source_frame_count, confidence, first_seen_ts, last_updated_ts)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(info.geohash7, info.sub_area_id, info.tb, info.dbk, scene_label,
        JSON.stringify(common_objects), JSON.stringify(common_ocr),
        JSON.stringify(reps), frames.length, confidence, Date.now(), Date.now());
    }
    changed++;
  }
  db.prepare(`INSERT INTO consolidation_log (ts, job_type, records_processed, records_changed, duration_ms)
    VALUES (?,?,?,?,?)`).run(Date.now(), 'extract_schemas', processed, changed, Date.now() - t0);
  return { processed, changed, duration_ms: Date.now() - t0 };
}

// ─── COGNITIVE MAP SEMANTIC INFERENCE ───────────────────────────────
// Use visit patterns to infer place type: residence (lots of nights),
// workplace (weekday daytime), transit (single brief visits), etc.
export function inferPlaceTypes(db) {
  const t0 = Date.now();
  let changed = 0;
  // Look at distinct visits, not raw frames
  const places = db.prepare('SELECT * FROM cognitive_map WHERE visit_count >= 2').all();
  for (const p of places) {
    const allFrames = db.prepare('SELECT hour_of_day, day_of_week, ts FROM episodic_memory WHERE geohash7=? ORDER BY ts').all(p.geohash7);
    if (allFrames.length < 3) continue;

    // Cluster into distinct visits
    const VISIT_GAP_MS = 2 * 3600 * 1000;
    const visitClusters = [];
    for (const f of allFrames) {
      if (visitClusters.length && f.ts - visitClusters[visitClusters.length-1].end <= VISIT_GAP_MS) {
        visitClusters[visitClusters.length-1].end = f.ts;
        visitClusters[visitClusters.length-1].sample_hour = f.hour_of_day;
        visitClusters[visitClusters.length-1].sample_dow = f.day_of_week;
      } else {
        visitClusters.push({ start: f.ts, end: f.ts, sample_hour: f.hour_of_day, sample_dow: f.day_of_week });
      }
    }

    // Heuristics — based on visit-level patterns
    const totalVisits = visitClusters.length;
    const eveningOrNight = visitClusters.filter(v => {
      const h = new Date(v.start).getUTCHours();
      return h >= 18 || h < 7;
    }).length;
    const weekdayDaytime = visitClusters.filter(v => {
      const h = new Date(v.start).getUTCHours();
      const d = new Date(v.start).getUTCDay();
      return d >= 1 && d <= 5 && h >= 9 && h < 17;
    }).length;
    const weekendOnly = visitClusters.filter(v => {
      const d = new Date(v.start).getUTCDay();
      return d === 0 || d === 6;
    }).length;

    let inferred = null;
    // Residence: high frequency + presence at evening/night hours (not just one daytime burst)
    if (totalVisits >= 10 && eveningOrNight / totalVisits >= 0.25) inferred = 'residence';
    // Workplace: ≥5 distinct visits with weekday daytime majority
    else if (totalVisits >= 5 && weekdayDaytime / totalVisits > 0.6) inferred = 'workplace';
    // Habit: ≥5 distinct visits but small frame count per visit (in-and-out, like gym, coffee)
    else if (totalVisits >= 5 && allFrames.length / totalVisits < 8) inferred = 'habit';
    // Leisure: weekend dominant
    else if (totalVisits >= 3 && weekendOnly / totalVisits > 0.6) inferred = 'leisure';
    // Transit: rare, brief
    else if (totalVisits <= 2 && p.median_visit_gap_days != null && p.median_visit_gap_days > 30) inferred = 'transit';
    else inferred = 'occasional';

    if (inferred !== p.inferred_place_type) {
      db.prepare('UPDATE cognitive_map SET inferred_place_type=?, updated_ts=? WHERE id=?').run(inferred, Date.now(), p.id);
      changed++;
    }
  }
  db.prepare(`INSERT INTO consolidation_log (ts, job_type, records_processed, records_changed, duration_ms)
    VALUES (?,?,?,?,?)`).run(Date.now(), 'infer_place_types', places.length, changed, Date.now() - t0);
  return { processed: places.length, changed };
}

// ─── ROUTINE DETECTION (Phase 3 — basic version) ────────────────────
// For each location with ≥5 visits, detect cadence.
export function detectRoutines(db) {
  const t0 = Date.now();
  let changed = 0;
  const places = db.prepare(`SELECT geohash7, semantic_label FROM cognitive_map WHERE visit_count >= 5`).all();
  for (const p of places) {
    const frames = db.prepare('SELECT hour_of_day, day_of_week, ts FROM episodic_memory WHERE geohash7=? ORDER BY ts').all(p.geohash7);
    if (frames.length < 5) continue;

    // Cluster into visits and compute gap between distinct visits
    const VISIT_GAP_MS = 2 * 3600 * 1000;
    const visitClusters = [];
    for (const f of frames) {
      if (visitClusters.length && f.ts - visitClusters[visitClusters.length-1].end <= VISIT_GAP_MS) {
        visitClusters[visitClusters.length-1].end = f.ts;
      } else {
        visitClusters.push({ start: f.ts, end: f.ts, hour: f.hour_of_day, dow: f.day_of_week });
      }
    }
    if (visitClusters.length < 3) continue;
    const visitGaps = [];
    for (let i = 1; i < visitClusters.length; i++) visitGaps.push((visitClusters[i].start - visitClusters[i-1].end) / 86400000);
    const sortedG = visitGaps.sort((a,b)=>a-b);
    const medianGap = sortedG[Math.floor(sortedG.length/2)];
    let cadence;
    if (medianGap < 0.5) cadence = 'multiple-daily';
    else if (medianGap < 1.5) cadence = 'daily';
    else if (medianGap < 4) cadence = 'few-times-weekly';
    else if (medianGap < 9) cadence = 'weekly';
    else if (medianGap < 35) cadence = 'monthly';
    else cadence = 'rare';

    // Typical hours from visit STARTS (not every frame)
    const hourBins = new Array(24).fill(0);
    for (const v of visitClusters) hourBins[v.hour]++;
    const topHours = hourBins.map((c, h) => ({ h, c })).sort((a,b)=>b.c-a.c).slice(0, 3).filter(x => x.c > 0).map(x => x.h).sort((a,b)=>a-b);

    // Typical days from visit STARTS
    const dayBins = new Array(7).fill(0);
    for (const v of visitClusters) dayBins[v.dow]++;
    const dayNames = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    const typicalDays = dayBins.map((c, d) => ({ d, c })).filter(x => x.c >= 2).map(x => dayNames[x.d]);

    // Variance: stddev of hour
    const meanH = hourBins.reduce((s, c, h) => s + h*c, 0) / frames.length;
    const variance = hourBins.reduce((s, c, h) => s + c*Math.pow(h - meanH, 2), 0) / frames.length;

    const human_label = `${p.semantic_label || p.geohash7}: ${cadence} ~${topHours.join(',')}h${typicalDays.length<7 ? ' '+typicalDays.join('/') : ''}`;

    const existing = db.prepare('SELECT id FROM routine_patterns WHERE geohash7=?').get(p.geohash7);
    if (existing) {
      db.prepare(`UPDATE routine_patterns SET cadence=?, typical_hours=?, typical_days=?,
        observation_count=?, variance_score=?, confidence=?, human_label=?, last_observed_ts=?, last_updated_ts=?
        WHERE id=?`).run(cadence, JSON.stringify(topHours), JSON.stringify(typicalDays),
        frames.length, variance, Math.min(0.95, frames.length/20), human_label, frames[frames.length-1].ts, Date.now(), existing.id);
    } else {
      db.prepare(`INSERT INTO routine_patterns
        (geohash7, semantic_label, cadence, typical_hours, typical_days, observation_count,
         variance_score, confidence, human_label, first_detected_ts, last_observed_ts, last_updated_ts)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(p.geohash7, p.semantic_label, cadence,
        JSON.stringify(topHours), JSON.stringify(typicalDays), frames.length, variance,
        Math.min(0.95, frames.length/20), human_label, frames[0].ts, frames[frames.length-1].ts, Date.now());
    }
    changed++;
  }
  db.prepare(`INSERT INTO consolidation_log (ts, job_type, records_processed, records_changed, duration_ms)
    VALUES (?,?,?,?,?)`).run(Date.now(), 'detect_routines', places.length, changed, Date.now() - t0);
  return { processed: places.length, changed };
}

// ─── PRUNE (visual redundancy) ──────────────────────────────────────
// Within each (geohash7, time_bucket, day_bucket) cluster, keep
// representative frames + drop redundant ones beyond the 30-day window.
export function pruneEpisodic(db, opts = { keepRecentDays: 7, keepRepsPerBucket: 5 }) {
  const t0 = Date.now();
  const cutoff = Date.now() - opts.keepRecentDays * 86400000;
  // Keep all frames newer than cutoff. For older, keep only IDs in any
  // place_schema's representative_episodic_ids list.
  const reps = new Set();
  const schemas = db.prepare('SELECT representative_episodic_ids FROM place_schemas').all();
  for (const s of schemas) {
    if (!s.representative_episodic_ids) continue;
    try { for (const id of JSON.parse(s.representative_episodic_ids)) reps.add(id); } catch {}
  }
  const toPrune = db.prepare(`SELECT id FROM episodic_memory WHERE ts < ? AND id NOT IN (${[...reps].join(',') || '0'})`).all(cutoff);
  const stmt = db.prepare('DELETE FROM episodic_memory WHERE id = ?');
  let pruned = 0;
  for (const r of toPrune) { stmt.run(r.id); pruned++; }
  db.prepare(`INSERT INTO consolidation_log (ts, job_type, records_processed, records_changed, duration_ms)
    VALUES (?,?,?,?,?)`).run(Date.now(), 'prune_episodic', toPrune.length + reps.size, pruned, Date.now() - t0,
    `kept ${reps.size} reps + ${cutoff} cutoff`);
  return { pruned, kept_reps: reps.size };
}

// ─── RUN ALL ────────────────────────────────────────────────────────
// CLI entrypoint: 'node consolidate.mjs' runs the full DMN pass.
if (import.meta.url === `file://${process.argv[1]}`) {
  const db = new Database('./data/cognitive.db');
  console.log('extractPlaceSchemas:', extractPlaceSchemas(db));
  console.log('inferPlaceTypes:   ', inferPlaceTypes(db));
  console.log('detectRoutines:    ', detectRoutines(db));
  // Skip prune in test runs (mock data should stay)
  // console.log('pruneEpisodic:     ', pruneEpisodic(db));
  db.close();
}
