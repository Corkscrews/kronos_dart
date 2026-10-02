/// Platforms without `dart:ffi` (the web) never use the kernel clock.
const bool kernelClockSupported = false;

int kernelMonotonicNanoseconds() => throw UnsupportedError('No kernel clock.');

int kernelWallNanoseconds() => throw UnsupportedError('No kernel clock.');

String? kernelBootIdentifier() => null;
