#pragma once

// Windows CNG (bcrypt.h) for ModelStore's SHA256. The Swift toolchain's WinSDK
// module map does not cover bcrypt.h, so this target exposes it. Empty
// elsewhere, because SwiftPM builds every target on every platform.
#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif
