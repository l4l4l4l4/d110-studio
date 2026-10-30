/// Raster dots relative to each fiducial's unchanged half-dot centre.
/// Three-dot strokes retain open corners rather than making a solid ink block.
const calibrationMarkerArm = 6;
const calibrationMarkerHalfStroke = 1;

bool calibrationMarkerInk(
  int dx,
  int dy, {
  int arm = calibrationMarkerArm,
  int halfStroke = calibrationMarkerHalfStroke,
}) =>
    (dx.abs() <= arm && dy.abs() <= halfStroke) ||
    (dy.abs() <= arm && dx.abs() <= halfStroke);
