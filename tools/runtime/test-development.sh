#!/bin/bash
# Offline smoke tests for the default development toolchains. Run as an unprivileged guest UID.
set -Eeuo pipefail
[ "$(id -u)" != 0 ] || { echo 'Development smoke tests must run without root.' >&2; exit 1; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kaoyu-development.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
cd "$scratch"
printf '#include <stdio.h>\nint main(void) { puts("c-ok"); return 0; }\n' > hello.c
gcc -Wall -Wextra -Werror hello.c -o hello-c
[ "$(./hello-c)" = c-ok ]
printf '#include <iostream>\nint main() { std::cout << "cpp-ok" << std::endl; }\n' > hello.cpp
g++ -std=c++20 -Wall -Wextra -Werror hello.cpp -o hello-cpp
[ "$(./hello-cpp)" = cpp-ok ]
printf 'cmake_minimum_required(VERSION 3.16)\nproject(kaoyu_smoke C)\nadd_executable(hello hello.c)\n' > CMakeLists.txt
cmake -S . -B build -G Ninja
cmake --build build
[ "$(build/hello)" = c-ok ]
pkg-config --exists libffi sqlite3 zlib openssl
python3 -m venv venv
venv/bin/python -m pip --version
venv/bin/python - <<'PY'
import ctypes, sqlite3, ssl, sysconfig, zlib
from pathlib import Path
assert Path(sysconfig.get_path('include'), 'Python.h').is_file()
assert sqlite3.connect(':memory:').execute('SELECT 42').fetchone()[0] == 42
assert zlib.decompress(zlib.compress(b'python-ok')) == b'python-ok'
PY
cat > kaoyu_ext.c <<'C'
#define PY_SSIZE_T_CLEAN
#include <Python.h>
static PyObject *answer(PyObject *self, PyObject *args) {
    (void)self; (void)args;
    return PyLong_FromLong(42);
}
static PyMethodDef methods[] = {{"answer", answer, METH_NOARGS, NULL}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "kaoyu_ext", NULL, -1, methods};
PyMODINIT_FUNC PyInit_kaoyu_ext(void) { return PyModule_Create(&module); }
C
read -r -a python_includes <<< "$(python3-config --includes)"
gcc -shared -fPIC "${python_includes[@]}" kaoyu_ext.c -o "kaoyu_ext$(python3-config --extension-suffix)"
venv/bin/python -c 'import kaoyu_ext; assert kaoyu_ext.answer() == 42'
node -e 'if (JSON.parse("{\"ok\":true}").ok !== true) process.exit(1)'
printf '%s\n' '{"name":"kaoyu-smoke","version":"1.0.0","scripts":{"test":"node --version"}}' > package.json
npm test --offline
cargo new --bin --vcs none rust-smoke
cd rust-smoke
cat > src/main.rs <<'RUST'
fn main() {
    println!("Hello, world!");
}

#[test]
fn arithmetic() {
    assert_eq!(2 + 2, 4);
}
RUST
cargo build --offline
cargo test --offline
cargo fmt --check
cargo clippy --offline -- -D warnings
[ "$(target/debug/rust-smoke)" = 'Hello, world!' ]
printf 'Development smoke tests passed: C/C++, CMake/Ninja, Python/venv, Node/npm, Rust/Cargo/fmt/clippy.\n'
