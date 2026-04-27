// THALAMIC RELAY — builds the system-prompt injection for one turn.
// Pulls relevant slices from each cortical region, weights by recency
// + cyclical-time match + place-affinity, formats compactly.
//
// Per-turn cost: pure SQL + string formatting. No LLM calls.
import Database from 'better-sqlite3';
import { encode as geohash } from './geohash.mjs';

const STALE_THRESHOLD_DAYS = 180;     // 6mo — older than this, mark STALE
const RECENCY_HALF_LIFE_DAYS = 30;    // exponential decay half-life

function timeBucket(hour) {
  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 17) return 'afternoon';
  if (hour >= 17 && hour < 22) return 'evening';
  return 'night';
}
function dayBucket(dow) { return (dow === 0 || dow === 6) ? 'weekend' : 'weekday'; }
function relativeTimeLabel(ms) {
  if (ms < 0) return 'just now';
  const min = Math.floor(ms / 60000);
  if (min < 60) return min + 'm ago';
  const hr = Math.floor(min / 60);
  if (hr < 24) return hr + 'h ago';
  const day = Math.floor(hr / 24);
  if (day < 7) return day + 'd ago';
  const wk = Math.floor(day / 7);
  if (wk < 4) return wk + 'w ago';
  const mo = Math.floor(day / 30);
  if (mo < 12) return mo + 'mo ago';
  return Math.floor(day / 365) + 'y ago';
}

// ─── ASSEMBLE INJECTION ─────────────────────────────────────────────
// Takes (context: { lat, lon, ts }) and returns either the formatted
// injection string OR null if there's nothing useful to inject.
export function assembleInjection(db, ctx) {
  const now = ctx.ts || Date.now();
  const nowD = new Date(now);
  const currentHour = nowD.getUTCHours();
  const currentDow = nowD.getUTCDay();
  const currentTb = timeBucket(currentHour);
  const currentDb = dayBucket(currentDow);

  if (ctx.lat == null || ctx.lon == null) {
    return assembleNoGPSFallback(db, ctx);
  }

  const gh7 = geohash(ctx.lat, ctx.lon, 7);
  const gh5 = geohash(ctx.lat, ctx.lon, 5);
const gh4 = geohash(ctx.lat, ctx.lon, 4);

  // Pull cognitive_map entry — what is this place
  const place = db.prepare('SELECT * FROM cognitive_map WHERE geohash7 = ?').get(gh7);
  // Compute the most recent distinct PRIOR visit (excluding current ~2h window)
  let lastPriorVisitTs = null;
  if (place) {
    const VISIT_GAP_MS = 2 * 3600 * 1000;
    const recentBoundary = now - VISIT_GAP_MS;
    const prior = db.prepare('SELECT ts FROM episodic_memory WHERE geohash7 = ? AND ts < ? ORDER BY ts DESC LIMIT 3').get(gh7, recentBoundary);
    lastPriorVisitTs = prior?.ts || null;
  }

// Pull schemas for THIS sub-area first; fall back to geohash7 if no sub-area match
  // (the sub_area filter happens AFTER currentSubArea is computed below)

// Pull DISTINCT nearby places by querying cognitive_map directly,
  // ordered by recency. Then we attach top schema + routine for each.
  const nearbyPlaces = db.prepare(`SELECT geohash7, semantic_label, inferred_place_type, last_visit_ts, visit_count
    FROM cognitive_map
    WHERE geohash7 LIKE ? AND geohash7 != ?
    ORDER BY last_visit_ts DESC LIMIT 8`).all(gh4 + '%', gh7);
  const nearbySchemas = nearbyPlaces.map(p => {
    const sa = db.prepare('SELECT scene_dominant, centroid_objects FROM sub_areas WHERE parent_geohash7 = ? ORDER BY member_count DESC LIMIT 1').get(p.geohash7);
    const schema = db.prepare('SELECT scene_label, common_objects FROM place_schemas WHERE geohash7 = ? ORDER BY confidence DESC LIMIT 1').get(p.geohash7);
    return {
      geohash7: p.geohash7,
      semantic_label: p.semantic_label,
      inferred_place_type: p.inferred_place_type,
      last_visit_ts: p.last_visit_ts,
      scene_label: sa?.scene_dominant || schema?.scene_label || null,
      common_objects: sa?.centroid_objects || schema?.common_objects || '[]',
    };
  });

  // Pull active routines for THIS location
  const routines = db.prepare('SELECT * FROM routine_patterns WHERE geohash7 = ?').all(gh7);

  // Pull recent episodic frames at THIS location (last 7d for context)
  const recentFrames = db.prepare(`SELECT id, ts, scene, objects, ocr_text
    FROM episodic_memory WHERE geohash7 = ? AND ts > ?
    ORDER BY ts DESC LIMIT 5`).all(gh7, now - 7*86400000);

  // Sub-area assignment for THIS frame: which room are we in within this building?
  // Match against existing sub_areas at this geohash7 by scene + object similarity
  // (uses ctx.scene + ctx.objects — passed in by the caller).
  let currentSubArea = null;
  let otherSubAreas = [];
  if (gh7) {
    const sas = db.prepare('SELECT * FROM sub_areas WHERE parent_geohash7 = ? ORDER BY member_count DESC').all(gh7);
    if (ctx.scene && ctx.objects) {
      // Score each sub-area
      let bestScore = 0;
      for (const sa of sas) {
        const sceneMatch = sa.scene_dominant === ctx.scene ? 1.0 : 0.3;
        const ctrObjs = (sa.centroid_objects ? JSON.parse(sa.centroid_objects) : []).map(o => o.obj);
        const interSet = new Set(ctrObjs);
        const inter = ctx.objects.filter(o => interSet.has(o)).length;
        const union = new Set([...ctrObjs, ...ctx.objects]).size;
        const objSim = union ? inter / union : 0;
        const score = sceneMatch * objSim;
        if (score > bestScore) { bestScore = score; currentSubArea = sa; }
      }
    }
    // Other sub-areas at this place (collapse duplicate scene_dominants)
    const seenScenes = new Set();
    if (currentSubArea) seenScenes.add(currentSubArea.scene_dominant);
    for (const sa of sas) {
      if (seenScenes.has(sa.scene_dominant)) continue;
      seenScenes.add(sa.scene_dominant);
      otherSubAreas.push(sa);
    }
  }

  // Sub-area-scoped schemas: use ONLY schemas for the current sub_area
  // when known. Falls back to geohash7-wide if we haven't matched a sub-area.
  const schemas = currentSubArea
    ? db.prepare('SELECT * FROM place_schemas WHERE sub_area_id = ? ORDER BY confidence DESC').all(currentSubArea.id)
    : db.prepare('SELECT * FROM place_schemas WHERE geohash7 = ? ORDER BY confidence DESC').all(gh7);

  // Lighting state for current context (matches what ingest computes)
  const ctxHour = nowD.getUTCHours();
  const isDayNow = ctxHour >= 8 && ctxHour < 18;
  const isNightNow = ctxHour >= 22 || ctxHour < 5;
  const ctxLighting = isNightNow ? 'dim/dark' : isDayNow ? 'bright' : 'typical';

// Recent UTTERANCES at this location/sub-area (auditory recall)
  // — what the user has been talking about here recently
  let recentUtterances = [];
  if (gh7) {
    recentUtterances = db.prepare(`SELECT transcript, ts, source FROM episodic_memory
      WHERE geohash7 = ? AND transcript IS NOT NULL AND ts > ?
      ORDER BY ts DESC LIMIT 6`).all(gh7, now - 7*86400000);
  }

  // Affect tags (corrections/reactions) for this location
  const corrections = db.prepare(`SELECT signal_text, was_response_text, corrected_to_text, ts
    FROM affect_tags WHERE geohash7 = ? AND signal_type = 'user_correction'
    ORDER BY ts DESC LIMIT 3`).all(gh7);

  // Build injection
  const dayName = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][currentDow];
  const tbName = currentTb;
  const lines = [];
lines.push('<visual-memory hidden="true">');
  // CURRENT FRAME — what the user can see right now (passed by caller).
  // Lets the model spot novelty (unusual_object not in schema → new thing).
  if (ctx.scene || (ctx.objects && ctx.objects.length)) {
    const sceneStr = ctx.scene || 'unknown';
    const objStr = ctx.objects && ctx.objects.length ? ctx.objects.join(', ') : '(none detected)';
    lines.push('[CURRENT FRAME: scene=' + sceneStr + ' objects=' + objStr + ']');
  }
  lines.push('[NOW: ' + dayName + ' ' + (currentHour < 10 ? '0' + currentHour : currentHour) + ':00 ' + tbName + ' (' + currentDb + ') | lighting:' + ctxLighting + ']');

  // HERE — current location summary
  if (place) {
    const lastVisitMs = lastPriorVisitTs ? now - lastPriorVisitTs : null;
    const isStale = lastPriorVisitTs ? (now - lastPriorVisitTs) > STALE_THRESHOLD_DAYS * 86400000 : false;
    const placeName = place.semantic_label || (place.inferred_place_type || 'unnamed location');
    const cadence = routines[0]?.cadence || (place.median_visit_gap_days
      ? (place.median_visit_gap_days < 1 ? 'often' : place.median_visit_gap_days < 8 ? 'weekly' : 'occasional')
      : null);

    const subAreaLabel = currentSubArea
      ? ' > ' + (currentSubArea.user_label || currentSubArea.scene_dominant || 'sub_area_' + currentSubArea.id)
      : '';
    let header = '[HERE: ' + placeName + subAreaLabel +
      ' | visit #' + place.visit_count;
    if (lastVisitMs != null) header += ' | last visit ' + relativeTimeLabel(lastVisitMs);
    else header += ' | first visit';
    if (cadence) header += ' | ' + cadence;
    if (isStale) header += ' | STALE — last seen >6mo, context may be outdated';
    header += ' | lighting:' + ctxLighting + ']';
    lines.push(header);

    // Schemas: prioritize CURRENT time bucket on CURRENT day bucket
    const matchingSchema = schemas.find(s => s.time_bucket === currentTb && s.day_bucket === currentDb);
    const otherSchemas = schemas.filter(s => s !== matchingSchema).slice(0, 2);

    if (matchingSchema) {
      const objs = JSON.parse(matchingSchema.common_objects || '[]')
        .slice(0, 6).map(o => o.obj).join(', ');
      lines.push('  ' + currentTb + '/' + currentDb + ' (typical): ' + objs +
        (matchingSchema.scene_label ? ' [' + matchingSchema.scene_label + ']' : ''));
    }
    for (const s of otherSchemas) {
      const objs = JSON.parse(s.common_objects || '[]').slice(0, 5).map(o => o.obj).join(', ');
      lines.push('  ' + s.time_bucket + '/' + s.day_bucket + ': ' + objs);
    }

    // Recent frames if no schema yet (early in learning)
    if (!matchingSchema && recentFrames.length) {
      for (const f of recentFrames.slice(0, 2)) {
        const objs = f.objects ? JSON.parse(f.objects).slice(0, 5).join(', ') : '';
        lines.push('  ' + relativeTimeLabel(now - f.ts) + ' (raw): ' + objs);
      }
    }

    // ROUTINE pattern (Cortical schema): explicit days/hours user is here
    if (routines.length > 0) {
      const r = routines[0];
      const days = r.typical_days ? JSON.parse(r.typical_days) : [];
      const hours = r.typical_hours ? JSON.parse(r.typical_hours) : [];
      const daysStr = days.length > 0 && days.length < 7 ? days.join('/') : (days.length === 7 ? 'all-week' : '');
      const hoursStr = hours.length ? hours.map(h => h + 'h').join(',') : '';
      lines.push('  ROUTINE: ' + r.cadence + (daysStr ? ' on ' + daysStr : '') + (hoursStr ? ' around ' + hoursStr : ''));
    }

    // Corrections override schemas — these are user-grounded truth
    for (const c of corrections) {
      lines.push('  ⚠ correction (' + relativeTimeLabel(now - c.ts) + '): ' +
        (c.corrected_to_text || c.signal_text));
    }
  } else {
    lines.push('[HERE: NO PRIOR MEMORY of this location | gps:' + ctx.lat.toFixed(4) + ',' + ctx.lon.toFixed(4) + ']');
    lines.push('  → User has not been here before (no episodic data at this geohash7 or nearby).');
    lines.push('  → DO NOT invent a place name. Acknowledge unfamiliar location.');
  }

  // NEARBY POIs from Apple MapKit (passed in by caller as ctx.nearby_pois).
  // Closes the "what hospital is this?" gap when cognitive memory has no
  // visit data here. Lists closest businesses/buildings with distance + category.
  if (Array.isArray(ctx.nearby_pois) && ctx.nearby_pois.length > 0) {
    lines.push('[NEARBY BUILDINGS / BUSINESSES (Apple Maps, ~250m radius):]');
    for (const p of ctx.nearby_pois.slice(0, 6)) {
      const cat = p.category ? ' (' + p.category + ')' : '';
      const dist = (p.distance_m != null) ? ' · ' + p.distance_m + 'm' : '';
      lines.push('  ' + (p.name || 'unnamed') + cat + dist);
    }
  }

  // OTHER ROOMS / SUB-AREAS at this same building — micro-precision
  if (otherSubAreas.length > 0 && place) {
    // For each other room, list its dominant objects (top-6) including
    // both persistent + transient — covers "where's my coffee mug" queries
    // even though mug is transient in kitchen.
    const labels = otherSubAreas.slice(0, 5).map(sa => {
      const objs = JSON.parse(sa.centroid_objects || '[]').slice(0, 10).map(o => o.obj).join(',');
      return (sa.user_label || sa.scene_dominant || 'sub_area') + '[' + objs + ']';
    });
    lines.push('  other rooms here: ' + labels.join(' | '));
  }

// RECENT UTTERANCES — what user has said/asked here recently
  if (recentUtterances.length > 0) {
    lines.push('  recently said here:');
    for (const u of recentUtterances.slice(0, 4)) {
      const trim = u.transcript.length > 80 ? u.transcript.slice(0, 80) + '...' : u.transcript;
      lines.push('    [' + relativeTimeLabel(now - u.ts) + '] "' + trim.replace(/"/g, "'") + '"');
    }
  }

  // NEARBY — other places within ~5km
if (nearbySchemas.length > 0) {
    lines.push('[NEARBY ~5km — places you visit:]');
    const seen = new Set();
    for (const ns of nearbySchemas) {
      if (seen.has(ns.geohash7)) continue;
      seen.add(ns.geohash7);
      // Pull routine for this nearby place
      const nbRoutine = db.prepare('SELECT cadence, typical_days, typical_hours FROM routine_patterns WHERE geohash7 = ?').get(ns.geohash7);
      // Pull scene label from sub_area for clarity (cafe, grocery_store, etc)
      const nbSubArea = db.prepare('SELECT scene_dominant FROM sub_areas WHERE parent_geohash7 = ? ORDER BY member_count DESC LIMIT 1').get(ns.geohash7);
      const sceneLabel = nbSubArea?.scene_dominant || ns.scene_label || 'place';
      const semanticName = ns.semantic_label || sceneLabel;  // e.g. 'cafe' not 'habit'
      const visited = ns.last_visit_ts ? relativeTimeLabel(now - ns.last_visit_ts) : 'unknown';
      const cadenceStr = nbRoutine ? ' [' + nbRoutine.cadence + (nbRoutine.typical_days ? ' on ' + JSON.parse(nbRoutine.typical_days).join('/') : '') + ']' : '';
      const objs = JSON.parse(ns.common_objects || '[]').slice(0, 5).map(o => o.obj).join(', ');
      lines.push('  ' + semanticName + cadenceStr + ' (' + visited + '): ' + objs);
    }
  }

  lines.push('</visual-memory>');
  lines.push('');
  lines.push("RULES — silent context. The user knows where they are.");
  lines.push("- NEVER restate the user's location, room, or activity unless they ASK.");
  lines.push("  Bad: 'You're in your kitchen at home.'");
  lines.push("  Bad: 'It's Tuesday evening at your gym.'");
  lines.push("  Good: just answer the question. Use location to ground, not narrate.");
  lines.push("- NEVER reference memory/data: no 'based on memory', 'in my data',");
  lines.push("  'from what I see', 'marked as', 'my information'.");
  lines.push("- DO speak as if you simply KNOW: 'your coffee mug is in the kitchen'.");
  lines.push("- For STALE: 'I think you moved out a while ago' — never 'data is stale'.");
  lines.push("- For NEW: 'I don't know this place' — never reference coordinates.");
  lines.push("- For NO GPS: 'I can't tell where you are'.");
  lines.push("- ⚠ user-corrections OVERRIDE everything else.");
  lines.push("- ONE sentence is usually enough. Brief, direct, like a friend.");
  lines.push("- NOVELTY: only mention something new if user ASKS what's new.");

  return lines.join('\n');
}

function assembleNoGPSFallback(db, ctx) {
  const recent = db.prepare(`SELECT scene, objects, ts FROM episodic_memory
    WHERE ts > ? ORDER BY ts DESC LIMIT 3`).all(Date.now() - 86400000);
  // Always emit at least a baseline so model knows the situation
  if (recent.length === 0) {
    return '<visual-memory hidden="true" no-gps="true">\n[NO LOCATION + NO RECENT MEMORY — first session or fresh device]\n</visual-memory>\nRULES: no spatial context available. Be honest if asked location-related questions. Do not invent a place.';
  }
  const lines = ['<visual-memory hidden="true" no-gps="true">'];
  lines.push('[NO LOCATION DATA — recent context only]');
  for (const f of recent) {
    const objs = f.objects ? JSON.parse(f.objects).slice(0, 5).join(', ') : '';
    lines.push('  ' + relativeTimeLabel(Date.now() - f.ts) + ': ' + (f.scene || '') + ' ' + objs);
  }
  lines.push('</visual-memory>');
  return lines.join('\n');
}

// CLI test
if (import.meta.url === `file://${process.argv[1]}`) {
  const db = new Database('./data/cognitive.db');
  const ctx = {
    lat: parseFloat(process.argv[2]) || 40.7128,
    lon: parseFloat(process.argv[3]) || -74.0060,
    ts: Date.now()
  };
  const inj = assembleInjection(db, ctx);
  console.log(inj || '(no injection — empty memory)');
  db.close();
}
