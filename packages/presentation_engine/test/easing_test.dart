import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

void main() {
  group('easing functions', () {
    test('linear is identity, endpoints exact', () {
      expect(applyEasing(Easing.linear, 0), 0.0);
      expect(applyEasing(Easing.linear, 0.25), 0.25);
      expect(applyEasing(Easing.linear, 1), 1.0);
    });

    test('easeIn is cubic t^3', () {
      expect(applyEasing(Easing.easeIn, 0.5), 0.125);
      expect(applyEasing(Easing.easeIn, 0), 0.0);
      expect(applyEasing(Easing.easeIn, 1), 1.0);
    });

    test('easeOut is cubic 1-(1-t)^3', () {
      expect(applyEasing(Easing.easeOut, 0.5), 0.875);
      expect(applyEasing(Easing.easeOut, 0), 0.0);
      expect(applyEasing(Easing.easeOut, 1), 1.0);
    });

    test('easeInOut is piecewise cubic, symmetric at the midpoint', () {
      expect(applyEasing(Easing.easeInOut, 0.25), 0.0625);
      expect(applyEasing(Easing.easeInOut, 0.5), 0.5);
      expect(applyEasing(Easing.easeInOut, 0.75), 0.9375);
      expect(applyEasing(Easing.easeInOut, 0), 0.0);
      expect(applyEasing(Easing.easeInOut, 1), 1.0);
    });

    test('step holds 0 until the segment end', () {
      expect(applyEasing(Easing.step, 0), 0.0);
      expect(applyEasing(Easing.step, 0.999), 0.0);
      expect(applyEasing(Easing.step, 1), 1.0);
    });

    test('progress is clamped to 0..1', () {
      expect(applyEasing(Easing.linear, -0.5), 0.0);
      expect(applyEasing(Easing.easeIn, 2), 1.0);
    });
  });
}
