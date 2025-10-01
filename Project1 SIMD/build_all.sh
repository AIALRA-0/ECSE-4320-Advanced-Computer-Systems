#!/bin/bash
set -e  # Exit immediately on error

# Top-level path
ROOT_DIR=$(pwd)

# Output directories
REPORT_SCALAR="$ROOT_DIR/gcc_vectorize_report.scalar.txt"
REPORT_SIMD="$ROOT_DIR/gcc_vectorize_report.simd.txt"

echo "===================="
echo "1. Compile Scalar version"
echo "===================="

# Clean and create build_scalar
rm -rf build_scalar
mkdir -p build_scalar
cd build_scalar

# Configure and compile
cmake -DFTZ_DAZ=ON -DBUILD_SCALAR=ON ..
make clean
make VERBOSE=1 2>"$REPORT_SCALAR"

echo "[Scalar] Vectorization report output to: $REPORT_SCALAR"
echo "[Scalar] grep -i vector result:"
grep -i vector "$REPORT_SCALAR" || echo "No vector-related output (expected)"

cd "$ROOT_DIR"

echo
echo "===================="
echo "2. Compile SIMD version"
echo "===================="

# Clean and create build_simd
rm -rf build
mkdir -p build
cd build

# Configure and compile
cmake -DFTZ_DAZ=ON -DBUILD_SCALAR=OFF ..
make clean
make VERBOSE=1 2>"$REPORT_SIMD"

echo "[SIMD] Vectorization report output to: $REPORT_SIMD"
echo "[SIMD] grep -i vector result:"
grep -i vector "$REPORT_SIMD" || echo "No vector-related output (please check)"

cd "$ROOT_DIR"

echo
echo "===================="
echo "All builds completed ✅"
echo "===================="
