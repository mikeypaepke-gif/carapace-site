// Minimal geohash encoder — geohash-32 character alphabet.
// 7 chars → ~150m × 150m precision (room/building scale)
// 5 chars → ~5km × 5km precision (neighborhood)
// 4 chars → ~40km × 40km precision (city region)
//
// Encoding from https://en.wikipedia.org/wiki/Geohash
const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
export function encode(lat, lon, precision = 7) {
  if (lat == null || lon == null) return null;
  let latRange = [-90, 90], lonRange = [-180, 180];
  let bits = 0, bit = 0, evenBit = true, geohash = '';
  while (geohash.length < precision) {
    if (evenBit) {
      const mid = (lonRange[0] + lonRange[1]) / 2;
      if (lon >= mid) { bits = (bits << 1) | 1; lonRange[0] = mid; }
      else { bits = bits << 1; lonRange[1] = mid; }
    } else {
      const mid = (latRange[0] + latRange[1]) / 2;
      if (lat >= mid) { bits = (bits << 1) | 1; latRange[0] = mid; }
      else { bits = bits << 1; latRange[1] = mid; }
    }
    evenBit = !evenBit;
    if (++bit === 5) { geohash += BASE32[bits]; bits = 0; bit = 0; }
  }
  return geohash;
}
