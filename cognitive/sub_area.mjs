// SUB-AREA DETECTION — emergent clustering within a geohash7 bucket.
// Similarity: scene_match × jaccard(objects). When featureprint is
// available (iOS-side), multiply by featureprint cosine too.
//
// MERGE_THRESHOLD: similarity above which a frame joins an existing cluster.
// Below this, a new sub-area is created. Tuning lever — too low merges
// distinct rooms together, too high fragments rooms into sub-clusters.
const MERGE_THRESHOLD = 0.4;

function jaccard(a, b) {
  if (!a || !b) return 0;
  const sa = new Set(a), sb = new Set(b);
  let inter = 0;
  for (const x of sa) if (sb.has(x)) inter++;
  const union = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

// Persistent-object clustering: cluster identity is anchored to objects
// that appear in ≥50% of frames. Transient objects (coffee_mug, wine_glass)
// don't define identity — they're lighting/time-of-day noise. This makes
// kitchen-at-noon and kitchen-at-midnight cluster together cleanly.
const PERSISTENCE_THRESHOLD = 0.5;
const COLD_START_FRAMES = 3;  // below this, treat all objects as persistent

function similarity(frame, subArea) {
  // Apple Vision's sceneSummary returns descriptive sentences that
  // vary frame-to-frame ("dark evening scene, stationary..." vs
  // "dim evening scene, stationary..."). Exact-match scene compare
  // tanked similarity even when objects perfectly overlapped, causing
  // sub-area fragmentation. Switched to weighted-additive: object
  // overlap dominates, scene similarity is a lighter signal.
  //
  // Scene similarity now uses keyword overlap on stemmed words rather
  // than exact-match — "dark kitchen morning" vs "dim kitchen evening"
  // both share "kitchen".
  const sceneMatch = sceneOverlap(frame.scene, subArea.scene_dominant);
  const frameObjs = frame.objects || [];
  const ctrObjs = subArea.centroid_objects ? JSON.parse(subArea.centroid_objects) : [];
  const isCold = subArea.member_count < COLD_START_FRAMES;
  const persistentObjs = isCold
    ? ctrObjs.map(o => o.obj)
    : ctrObjs.filter(o => o.freq >= PERSISTENCE_THRESHOLD).map(o => o.obj);
  let objMatch;
  if (persistentObjs.length === 0) {
    const allObjs = ctrObjs.map(o => o.obj);
    objMatch = jaccard(frameObjs, allObjs);
  } else {
    const persistSet = new Set(persistentObjs);
    const hits = frameObjs.filter(o => persistSet.has(o)).length;
    objMatch = persistentObjs.length > 0 ? hits / persistentObjs.length : 0;
  }
  // Weighted blend — objects dominate (70%), scene supports (30%).
  // With identical objects + totally different scene strings: 0.7 + 0 = 0.7 → merge.
  // With totally different objects + same scene: 0 + 0.3 = 0.3 → new area.
  // With moderate overlap on both: ~0.5 → borderline (intended).
  return 0.7 * objMatch + 0.3 * sceneMatch;
}

function sceneOverlap(a, b) {
  if (!a || !b) return 0;
  // Tokenize: lowercase, split on non-letters, drop short stopwords
  const stop = new Set(['the','a','an','of','in','on','at','is','it','to','and','with','for','this','that','near','room','scene','detected','maybe','visible','stationary']);
  const tok = (s) => new Set(s.toLowerCase().split(/[^a-z]+/).filter(w => w.length > 2 && !stop.has(w)));
  const sa = tok(a), sb = tok(b);
  if (sa.size === 0 || sb.size === 0) return 0;
  let inter = 0;
  for (const w of sa) if (sb.has(w)) inter++;
  const union = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

// Find or create the sub_area for this frame within its geohash7.
// Returns sub_area_id and updates the centroid.
export function assignSubArea(db, geohash7, frame, ts) {
  if (!geohash7) return null;
  const candidates = db.prepare('SELECT * FROM sub_areas WHERE parent_geohash7 = ?').all(geohash7);

  // Score each candidate
  let best = null, bestScore = 0;
  for (const c of candidates) {
    const s = similarity(frame, c);
    if (s > bestScore) { bestScore = s; best = c; }
  }

  if (best && bestScore >= MERGE_THRESHOLD) {
    // Merge: update centroid as weighted average
    const existingObjs = JSON.parse(best.centroid_objects || '[]');
    const objCounts = {};
    for (const e of existingObjs) objCounts[e.obj] = e.freq * best.member_count;
    if (frame.objects) for (const o of frame.objects) objCounts[o] = (objCounts[o] || 0) + 1;
    const newCount = best.member_count + 1;
    const updatedObjs = Object.entries(objCounts)
      .map(([obj, cnt]) => ({ obj, freq: +(cnt / newCount).toFixed(2) }))
      .sort((a, b) => b.freq - a.freq).slice(0, 12);

    db.prepare(`UPDATE sub_areas SET member_count=?, last_seen_ts=?,
      centroid_objects=?, scene_dominant=COALESCE(scene_dominant, ?)
      WHERE id=?`).run(newCount, ts, JSON.stringify(updatedObjs),
      frame.scene, best.id);
    return best.id;
  }

  // New sub-area
  const seedObjs = (frame.objects || []).map(o => ({ obj: o, freq: 1.0 }));
  const result = db.prepare(`INSERT INTO sub_areas
    (parent_geohash7, scene_dominant, centroid_objects, member_count,
     first_seen_ts, last_seen_ts, auto_label)
    VALUES (?, ?, ?, ?, ?, ?, ?)`).run(
      geohash7, frame.scene || null, JSON.stringify(seedObjs),
      1, ts, ts, frame.scene || 'sub_area');
  return result.lastInsertRowid;
}

// Re-cluster all frames at a geohash7 from scratch (for consolidation).
// Useful after enough data has accumulated to refine clusters.
export function recluster(db, geohash7) {
  // Phase 1: just seed from existing data, drop and re-run assignment
  db.prepare('DELETE FROM sub_areas WHERE parent_geohash7 = ?').run(geohash7);
  db.prepare('UPDATE episodic_memory SET sub_area_id = NULL WHERE geohash7 = ?').run(geohash7);
  const frames = db.prepare('SELECT id, ts, scene, objects FROM episodic_memory WHERE geohash7 = ? ORDER BY ts').all(geohash7);
  for (const f of frames) {
    const objs = f.objects ? JSON.parse(f.objects) : [];
    const sa_id = assignSubArea(db, geohash7, { scene: f.scene, objects: objs }, f.ts);
    db.prepare('UPDATE episodic_memory SET sub_area_id = ? WHERE id = ?').run(sa_id, f.id);
  }
  return frames.length;
}

// Auto-label a sub-area from its dominant scene + top object
export function autoLabelSubArea(sa) {
  const objs = JSON.parse(sa.centroid_objects || '[]');
  if (objs.length === 0) return sa.scene_dominant || 'sub_area';
  const topObj = objs[0].obj.split('_').pop();   // 'stainless_fridge' → 'fridge'
  if (sa.scene_dominant) {
    return sa.scene_dominant + (objs.length > 0 ? ':' + topObj : '');
  }
  return topObj;
}
