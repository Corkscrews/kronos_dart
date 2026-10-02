import 'dart:ffi';
import 'dart:io' show File, Platform;

// <_time.h> clock IDs, iOS 10+ / macOS 10.12+.
const int _darwinRealtime = 0;
const int _darwinMonotonicRaw = 4;
const String _bootSessionName = 'kern.bootsessionuuid';

// <linux/time.h> clock IDs.
const int _linuxRealtime = 0;
const int _linuxBoottime = 7;
const String _linuxBootIdPath = '/proc/sys/kernel/random/boot_id';

final bool _darwin = Platform.isIOS || Platform.isMacOS;

/// Whether the kernel clocks can be read on this platform.
final bool kernelClockSupported =
    _darwin || Platform.isAndroid || Platform.isLinux;

final DynamicLibrary _process = DynamicLibrary.process();

final DynamicLibrary _libc =
    Platform.isAndroid ? DynamicLibrary.open('libc.so') : _process;

final int Function(int) _clockNanoseconds = _process
    .lookupFunction<Uint64 Function(Int32), int Function(int)>(
      'clock_gettime_nsec_np',
      isLeaf: true,
    );

final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

final int Function(int, Pointer<_Timespec>) _clockGettime = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<_Timespec>),
      int Function(int, Pointer<_Timespec>)
    >('clock_gettime', isLeaf: true);

// ponytail: one buffer per isolate, never freed; attach a NativeFinalizer if
// apps spawn isolates by the million.
final Pointer<_Timespec> _timespec =
    _libc
        .lookupFunction<
          Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)
        >('malloc')(sizeOf<_Timespec>())
        .cast();

int _linuxNanoseconds(int clock) {
  if (_clockGettime(clock, _timespec) != 0) {
    throw StateError('clock_gettime($clock) failed.');
  }
  final time = _timespec.ref;
  return time.seconds * 1000000000 + time.nanoseconds;
}

/// Nanoseconds of a clock that keeps counting during sleep: Darwin
/// `CLOCK_MONOTONIC_RAW` (`mach_continuous_time`), Linux `CLOCK_BOOTTIME`.
int kernelMonotonicNanoseconds() =>
    _darwin
        ? _clockNanoseconds(_darwinMonotonicRaw)
        : _linuxNanoseconds(_linuxBoottime);

/// `CLOCK_REALTIME` in nanoseconds; Darwin truncates it to the microsecond.
int kernelWallNanoseconds() =>
    _darwin
        ? _clockNanoseconds(_darwinRealtime)
        : _linuxNanoseconds(_linuxRealtime);

/// `kern.bootsessionuuid` on Darwin, the kernel `boot_id` on Linux, or null
/// when it can't be read.
String? kernelBootIdentifier() {
  try {
    if (!_darwin) {
      final id = File(_linuxBootIdPath).readAsStringSync().trim();
      return id.isEmpty ? null : id;
    }
    return _readBootSession();
  } on Object {
    return null;
  }
}

String? _readBootSession() {
  final malloc = _process.lookupFunction<
    Pointer<Uint8> Function(IntPtr),
    Pointer<Uint8> Function(int)
  >('malloc');
  final free = _process.lookupFunction<
    Void Function(Pointer<Uint8>),
    void Function(Pointer<Uint8>)
  >('free');
  final sysctlbyname = _process.lookupFunction<
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Size>,
      Pointer<Void>,
      Size,
    ),
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Size>,
      Pointer<Void>,
      int,
    )
  >('sysctlbyname');

  // One block: name at 0, size_t at 32, value buffer at 48.
  const capacity = 64;
  final block = malloc(48 + capacity);
  if (block == nullptr) return null;
  try {
    for (var i = 0; i < _bootSessionName.length; i++) {
      block[i] = _bootSessionName.codeUnitAt(i);
    }
    block[_bootSessionName.length] = 0;
    final size = (block + 32).cast<Size>()..value = capacity;
    final value = block + 48;
    if (sysctlbyname(block, value, size, nullptr, 0) != 0) return null;
    final units = <int>[
      for (var i = 0; i < size.value && value[i] != 0; i++) value[i],
    ];
    return units.isEmpty ? null : String.fromCharCodes(units);
  } finally {
    free(block);
  }
}
