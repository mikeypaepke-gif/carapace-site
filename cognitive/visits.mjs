// VISIT CLUSTERING — frames within VISIT_GAP_MS of each other = one visit.
// Solves the bug where intra-visit frame gaps (15min apart) made every
// recurring-daily place look 'multiple-daily.'
//
// One visit = a temporal cluster of frames at the same geohash7,
// where consecutive frames are separated by ≤ VISIT_GAP_MS.
export const VISIT_GAP_MS = 2 * 3600 * 1000;  // 2 hours

// Returns array of visit objects: { start_ts, end_ts, frame_count }
export function clusterVisits(frames) {
  if (frames.length === 0) return [];
  // Assumes frames sorted by ts ascending
  const visits = [{ start_ts: frames[0].ts, end_ts: frames[0].ts, frame_count: 1, frames: [frames[0]] }];
  for (let i = 1; i < frames.length; i++) {
    const last = visits[visits.length - 1];
    if (frames[i].ts - last.end_ts <= VISIT_GAP_MS) {
      last.end_ts = frames[i].ts;
      last.frame_count++;
      last.frames.push(frames[i]);
    } else {
      visits.push({ start_ts: frames[i].ts, end_ts: frames[i].ts, frame_count: 1, frames: [frames[i]] });
    }
  }
  return visits;
}

// Compute median gap between DISTINCT visits, not frames.
export function medianVisitGapDays(visits) {
  if (visits.length < 2) return null;
  const gaps = [];
  for (let i = 1; i < visits.length; i++) gaps.push(visits[i].start_ts - visits[i-1].end_ts);
  gaps.sort((a, b) => a - b);
  return gaps[Math.floor(gaps.length / 2)] / 86400000;
}

// Cadence label from gap.
export function gapToCadence(gapDays) {
  if (gapDays == null) return null;
  if (gapDays < 0.5) return 'multiple-daily';
  if (gapDays < 1.5) return 'daily';
  if (gapDays < 4) return 'few-times-weekly';
  if (gapDays < 9) return 'weekly';
  if (gapDays < 35) return 'monthly';
  return 'rare';
}
