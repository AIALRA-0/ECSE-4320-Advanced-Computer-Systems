# SIMD Advantage Evaluation

## Introduction 

A compact benchmark project comparing scalar and SIMD implementations  
of common numerical kernels (SAXPY, DOT, MUL, STENCIL)

It analyzes performance under different data sizes, strides, alignments, and data types, 
to study compute-bound vs. memory-bound behavior using metrics such as GFLOP/s, CPE, and Speedup

Please check `.\reports\Project 1 Report Lucas Ding.pdf` for detail :)

## Core Directory Structure

```
/
├── CMakeLists.txt       # Build configuration 
├── README.md            # Project overview 

├── src/                 # Source code directory
│   └── bench.cpp        # Core benchmark file implementing SAXPY, DOT, MUL, STENCIL kernels

├── scripts/             # Automation & analysis scripts
│   ├── run_all.sh               # Run all experiments 
│   ├── plot.py                  # Plot Speedup
│   ├── make_align_report.py     # Analyze alignment impact
│   ├── make_tail_report.py      # Analyze tail-handling overhead
│   ├── make_stride_report.py    # Analyze stride effects
│   ├── make_dtype_report.py     # Compare f32 vs f64 performance
│   └── make_roofline_report.py  # Generate Roofline model plots

├── data/                # Collected benchmark data 
│   ├── scalar.csv               # Scalar baseline results
│   ├── simd.csv                 # SIMD performance results
│   └── ...                      # Other aggregated data summaries

├── plots/               # Visualization outputs 
│   ├── speedup_*.png            # Speedup charts 
│   ├── gflops_*.png             # GFLOP/s charts per kernel
│   ├── stride/                  # Stride analysis figures
│   ├── dtype/                   # Data type comparison figures
│   └── roofline/                # Roofline model plots

└── reports/             # Documentation & analysis 
├── gcc_vectorize_report.*   # Compiler vectorization logs
├── *.asm                    # Disassembly files
└── Project 1 Report *.pdf   # Final formatted report 

```
