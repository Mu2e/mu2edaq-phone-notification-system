# Install, build and test

Short reference. The step-by-step walkthrough, including configuration,
enrollment and APNs, is [`GETTING-STARTED.md`](../GETTING-STARTED.md); how the
production instance is run is [OPERATIONS.md](OPERATIONS.md).

## Python server, publisher and CLI

Requires Python 3.9 or newer (`pyproject.toml:10`).

```bash
./bootstrap.sh                                  # Linux, macOS
PYTHON=python3.9 ./bootstrap.sh                 # pick the interpreter
```

`bootstrap.sh` creates `venv/`, installs `requirements.txt` (runtime
dependencies plus Authlib, pyzmq and pytest), installs the package editable,
and installs `../mu2edaq-discovery` editable if that sibling exists.

Windows 11 has no bootstrap script:

```powershell
py -3 -m venv venv
venv\Scripts\pip install -r requirements.txt -e .
```

Optional extras instead of the full `requirements.txt`:
`pip install -e '.[oidc]'`, `'.[zmq]'`, `'.[postgres]'`, `'.[dev]'`.

Run: `./start-mu2edaq-notify-server.sh` (see `man ./man/man1/start-mu2edaq-notify-server.sh.1`).
The shipped `config/notify-server.yaml` enables TLS with paths that exist only
on the production host; on any other host start with `--no-tls` or set
`server.tls`.

## C++ publisher library

Requires CMake 3.16+, a C++17 compiler and libcurl development files.
CppUnit is optional and enables the unit test.

```bash
cmake -S . -B build
cmake --build build
ctest --test-dir build              # "No tests were found" means CppUnit is absent
cmake --install build --prefix /opt/mu2edaq   # library, header, export set, publish_example
```

`cmake --install` currently installs no man pages: its `install(FILES ...)`
rules name the old flat `man/*.1` paths with `OPTIONAL` (`CMakeLists.txt:60-63`,
PNS-011). Read them in place (below) until that is fixed.

On Windows 11 (MSVC) `ws2_32` is linked automatically (`CMakeLists.txt:25-27`);
libcurl must be findable by `find_package(CURL)`. The install tree has no
package Config file, so out-of-tree consumers include
`lib/cmake/mu2edaq_notify/mu2edaq_notify-targets.cmake` after
`find_package(CURL)`; see `man ./man/man3/mu2edaq_notify_cpp.3`.

## iOS app

macOS with Xcode and XcodeGen; see [`ios/README.md`](../ios/README.md).

```bash
cd ios/Mu2eNotify && xcodegen generate && open Mu2eNotify.xcodeproj
```

## Tests

```bash
venv/bin/pytest -q                  # 185 tests; run from the repository root
ctest --test-dir build
```

Run pytest from the repository root.
`tests/test_dispatch.py::test_apns_alert_payload_is_plain_visible_notification`
resolves `config/apns_key.p8` against the working directory and fails (1 of
185) from anywhere else, or on a checkout without that gitignored key (#15).

## Man pages

```bash
man ./man/man1/mu2edaq-notify-server.1
MANPATH=$PWD/man:$MANPATH man mu2edaq_notify_cpp
```
