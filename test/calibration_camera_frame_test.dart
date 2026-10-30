import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:d110_studio/calibration_camera_frame.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

CalibrationCameraFrameSource _frame({
  required int width,
  required int height,
  required Uint8List bytes,
  int? rowStride,
  int pixelStride = 1,
  ImageFormatGroup format = ImageFormatGroup.yuv420,
}) => CalibrationCameraFrameSource.fromImage(
  CameraImage.fromPlatformInterface(
    CameraImageData(
      format: CameraImageFormat(
        format,
        raw: format == ImageFormatGroup.nv21 ? 17 : 35,
      ),
      width: width,
      height: height,
      planes: [
        CameraImagePlane(
          bytes: bytes,
          bytesPerRow: rowStride ?? width * pixelStride,
          bytesPerPixel: pixelStride,
        ),
      ],
    ),
  ),
);

List<int> _gray(Uint8List rgba) => [
  for (var i = 0; i < rgba.length; i += 4) rgba[i],
];

void main() {
  test('Y plane honours row and pixel strides and rotates clockwise', () {
    final image = _frame(
      width: 3,
      height: 2,
      rowStride: 8,
      pixelStride: 2,
      bytes: Uint8List.fromList([
        10,
        99,
        20,
        99,
        30,
        99,
        99,
        99,
        40,
        99,
        50,
        99,
        60,
      ]),
    );
    final frame = convertCalibrationCameraFrame(
      image,
      rotationDegrees: 90,
      lumaRange: CalibrationLumaRange.full,
    );
    expect((frame.width, frame.height), (2, 3));
    expect(_gray(frame.rgba), [40, 10, 50, 20, 60, 30]);
    expect([
      for (var i = 3; i < frame.rgba.length; i += 4) frame.rgba[i],
    ], everyElement(255));
  });

  test('NV21 ignores chroma and expands video-range luma explicitly', () {
    final image = _frame(
      width: 2,
      height: 2,
      format: ImageFormatGroup.nv21,
      bytes: Uint8List.fromList([16, 235, 0, 255, 128, 128]),
    );
    expect(
      _gray(convertCalibrationCameraFrame(image, rotationDegrees: 0).rgba),
      [0, 255, 0, 255],
    );
    expect(
      _gray(
        convertCalibrationCameraFrame(
          image,
          rotationDegrees: 180,
          lumaRange: CalibrationLumaRange.full,
        ).rgba,
      ),
      [255, 0, 235, 16],
    );
  });

  test('BGRA preserves colour and alpha without copying padded bytes', () {
    final image = _frame(
      width: 2,
      height: 1,
      rowStride: 12,
      pixelStride: 4,
      format: ImageFormatGroup.bgra8888,
      bytes: Uint8List.fromList([
        3,
        2,
        1,
        255,
        30,
        20,
        10,
        128,
        99,
        99,
        99,
        99,
      ]),
    );
    expect(convertCalibrationCameraFrame(image, rotationDegrees: 270).rgba, [
      10,
      20,
      30,
      128,
      1,
      2,
      3,
      255,
    ]);
  });

  test('large stream frames are bounded before allocating RGBA', () {
    final image = _frame(width: 3200, height: 2, bytes: Uint8List(6400));
    final frame = convertCalibrationCameraFrame(image, rotationDegrees: 90);
    expect((frame.width, frame.height), (1, 1600));
    expect(frame.rgba.length, 6400);
  });

  test('back sensor orientation follows portrait and both landscapes', () {
    expect(calibrationCameraRotation(90, DeviceOrientation.portraitUp), 90);
    expect(calibrationCameraRotation(90, DeviceOrientation.landscapeLeft), 0);
    expect(calibrationCameraRotation(90, DeviceOrientation.portraitDown), 270);
    expect(
      calibrationCameraRotation(90, DeviceOrientation.landscapeRight),
      180,
    );
    expect(
      calibrationCameraRotation(270, DeviceOrientation.landscapeLeft),
      180,
    );
  });

  test(
    'truncated planes and unsupported formats cannot masquerade as processed',
    () {
      expect(
        () => convertCalibrationCameraFrame(
          _frame(width: 2, height: 2, bytes: Uint8List(3)),
          rotationDegrees: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => convertCalibrationCameraFrame(
          _frame(
            width: 2,
            height: 2,
            bytes: Uint8List(4),
            format: ImageFormatGroup.jpeg,
          ),
          rotationDegrees: 0,
        ),
        throwsUnsupportedError,
      );
    },
  );
}
