-- ═══════════════════════════════════════════════════════════════════
--  COGNITIVE ARCHITECTURE — brain-region schema
-- ═══════════════════════════════════════════════════════════════════
--  Each table corresponds to a functional brain region. Phases 1-4
--  progressively fill them in. The architecture is set up day one so
--  later phases are 'fill in empty tables', not refactors.
--
--  Phase 1 (active): Hippocampus + Place Area + Cognitive Map
--  Phase 2: Amygdala (affect) + Basal Ganglia (efficacy)
--  Phase 3: Cortical Schemas (routines) + Cerebellum (prediction)
--  Phase 4: Auditory enrichment, cross-modal binding
-- ═══════════════════════════════════════════════════════════════════

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ─── HIPPOCAMPUS ─────────────────────────────────────────────────────
-- Episodic memory: every captured sensory frame, time + place tagged.
-- This is the rawest layer. Consolidation derives everything else
-- from this table.
CREATE TABLE IF NOT EXISTS episodic_memory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  iso_ts TEXT NOT NULL,
  -- Spatial (Entorhinal place/grid cell input)
  lat REAL, lon REAL, gps_accuracy REAL,
  geohash7 TEXT, geohash5 TEXT,
  -- Cyclical time
  hour_of_day INTEGER, day_of_week INTEGER, month_of_year INTEGER,
  -- Visual (V1 → ventral stream)
  scene TEXT, scene_confidence REAL,
  objects TEXT, ocr_text TEXT,
  featureprint BLOB, thumb_path TEXT,
  -- Auditory (A1, phase 4)
  transcript TEXT, speech_tone TEXT,
  -- Lighting state (V4 color-constancy analog)
  lighting_state TEXT,
  -- Source
  source TEXT, agent_id TEXT, device_id TEXT,
  sub_area_id INTEGER
);
CREATE INDEX IF NOT EXISTS idx_ep_geohash7_ts ON episodic_memory(geohash7, ts DESC);
CREATE INDEX IF NOT EXISTS idx_ep_ts ON episodic_memory(ts DESC);
CREATE INDEX IF NOT EXISTS idx_ep_scene ON episodic_memory(scene);

-- ─── ENTORHINAL GRID CELLS ───────────────────────────────────────────
-- Cognitive map: geohash → semantic place. Built up via repeat visits.
CREATE TABLE IF NOT EXISTS cognitive_map (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  geohash7 TEXT UNIQUE NOT NULL,
  semantic_label TEXT, semantic_label_source TEXT, semantic_confidence REAL,
  first_visit_ts INTEGER NOT NULL, last_visit_ts INTEGER NOT NULL,
  visit_count INTEGER NOT NULL DEFAULT 1,
  median_visit_gap_days REAL,
  inferred_place_type TEXT,
  updated_ts INTEGER NOT NULL
);

-- ─── PARAHIPPOCAMPAL PLACE AREA ──────────────────────────────────────
-- Place schemas: per-location time-bucketed abstracted summaries.
-- 'What's typically in the kitchen at morning on weekdays.'
CREATE TABLE IF NOT EXISTS place_schemas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  geohash7 TEXT NOT NULL,
  sub_area_id INTEGER REFERENCES sub_areas(id),
  time_bucket TEXT NOT NULL,
  day_bucket TEXT NOT NULL,
  scene_label TEXT,
  common_objects TEXT,
  common_ocr_terms TEXT,
  representative_episodic_ids TEXT,
  source_frame_count INTEGER NOT NULL,
  confidence REAL,
  first_seen_ts INTEGER NOT NULL,
  last_updated_ts INTEGER NOT NULL,
  UNIQUE(geohash7, sub_area_id, time_bucket, day_bucket)
);
CREATE INDEX IF NOT EXISTS idx_schemas_geohash ON place_schemas(geohash7);

-- ─── AMYGDALA (Phase 2) ─────────────────────────────────────────────
-- Affect tags: emotional valence on memories. Drives recall weighting.
CREATE TABLE IF NOT EXISTS affect_tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  episodic_id INTEGER, geohash7 TEXT, schema_id INTEGER,
  valence REAL NOT NULL,
  signal_type TEXT NOT NULL, signal_text TEXT,
  was_response_text TEXT, corrected_to_text TEXT
);
CREATE INDEX IF NOT EXISTS idx_affect_geohash_ts ON affect_tags(geohash7, ts DESC);

-- ─── BASAL GANGLIA (Phase 2) ────────────────────────────────────────
-- Response efficacy: what response styles worked here.
CREATE TABLE IF NOT EXISTS response_efficacy (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  geohash7 TEXT, scene TEXT,
  user_query_summary TEXT, response_style TEXT,
  efficacy_signal REAL, follow_up_seconds INTEGER,
  agent_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_eff_geohash_scene ON response_efficacy(geohash7, scene);

-- ─── CORTICAL SCHEMAS (Phase 3) ─────────────────────────────────────
-- Routine patterns: detected habits over time.
CREATE TABLE IF NOT EXISTS routine_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  geohash7 TEXT NOT NULL,
  semantic_label TEXT,
  cadence TEXT,
  typical_hours TEXT, typical_days TEXT,
  observation_count INTEGER NOT NULL,
  variance_score REAL, confidence REAL,
  human_label TEXT,
  first_detected_ts INTEGER NOT NULL,
  last_observed_ts INTEGER NOT NULL,
  last_updated_ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_routine_geohash ON routine_patterns(geohash7);

-- ─── CEREBELLUM (Phase 3) ───────────────────────────────────────────
-- Prediction log: expected vs actual, surprise weighting.
CREATE TABLE IF NOT EXISTS prediction_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  episodic_id INTEGER NOT NULL,
  predicted_scene TEXT, predicted_objects TEXT,
  actual_scene TEXT, actual_objects TEXT,
  surprise_score REAL
);
CREATE INDEX IF NOT EXISTS idx_pred_episodic ON prediction_log(episodic_id);

-- ─── DEFAULT MODE NETWORK (audit) ───────────────────────────────────
-- Consolidation log: what background jobs did. Debug + visibility.
CREATE TABLE IF NOT EXISTS consolidation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  job_type TEXT NOT NULL,
  records_processed INTEGER, records_changed INTEGER,
  duration_ms INTEGER, notes TEXT
);

-- ─── HIPPOCAMPAL SUB-AREAS (multi-scale place coding) ──────────────
-- Within a meso geohash7 bucket, frames cluster into sub-areas by
-- visual + object similarity. Brain does this via hierarchical place
-- cells firing at multiple scales simultaneously. We approximate with
-- emergent clustering — no user labels required.
CREATE TABLE IF NOT EXISTS sub_areas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  parent_geohash7 TEXT NOT NULL,
  -- Cluster identity
  scene_dominant TEXT,
  centroid_objects TEXT,                  -- JSON: top objects with frequency, the 'fingerprint'
  centroid_featureprint BLOB,             -- avg featureprint (Phase 1.5 — when iOS ships it)
  -- Auto-derived label
  auto_label TEXT,                        -- 'kitchen', 'living_room_north', etc — derived
  user_label TEXT,                        -- optional override from user/agent learning
  -- Stats
  member_count INTEGER NOT NULL DEFAULT 1,
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts INTEGER NOT NULL,
  internal_variance REAL                  -- how tight the cluster is; high → consider splitting
);
CREATE INDEX IF NOT EXISTS idx_sub_areas_parent ON sub_areas(parent_geohash7);

-- Add sub_area_id to episodic_memory (will be NULL for old rows)
-- Done as separate ALTER for back-compat with existing DBs.
