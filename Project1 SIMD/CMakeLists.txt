# 要求最低 CMake 版本
cmake_minimum_required(VERSION 3.16)

# 定义工程名 simd_bench，语言为 C++
project(simd_bench CXX)

# 使用 C++17 标准，并强制要求（不允许退回到更低标准）
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 定义选项：
# FTZ_DAZ：是否启用 flush-to-zero / denormals-are-zero（处理非正规数为 0）
# BUILD_SCALAR：是否构建仅标量版本（通过禁止自动向量化实现基线性能比较）
option(FTZ_DAZ "Enable flush-to-zero / denormals-are-zero" ON)
option(BUILD_SCALAR "Disable auto-vectorization for scalar baseline" OFF)

# 针对不同编译器设置优化选项
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  # Clang 编译器：
  # -O3                最高优化级别
  # -ffp-contract=fast 允许快速浮点合并（如使用 FMA）
  # -fno-exceptions    禁用异常，减少运行时开销
  # -fno-rtti          禁用 RTTI（运行时类型识别），减小体积
  # -DNDEBUG           禁用断言
  add_compile_options(-O3 -ffp-contract=fast -fno-exceptions -fno-rtti -DNDEBUG)

  # 如果要求构建标量基线，禁止 Clang 的自动向量化与 SLP 向量化
  if(BUILD_SCALAR)
    add_compile_options(-fno-vectorize -fno-slp-vectorize)
  endif()

  # -march=native 生成针对本机 CPU ISA（如 AVX2/AVX-512）的最优代码
  add_compile_options(-march=native)

elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  add_compile_options(-O3 -ffast-math -fno-exceptions -fno-rtti -DNDEBUG -march=native)

  if(BUILD_SCALAR)
    # 禁用向量化，构建标量基线
    add_compile_options(-fno-tree-vectorize -fopt-info-vec-optimized -fopt-info-vec-missed)
  else()
    # 启用向量化报告（optimized + missed）
    add_compile_options(-fopt-info-vec-optimized -fopt-info-vec-missed)
  endif()
endif()

# 关闭链接时优化（LTO）
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)
add_compile_options(-fno-lto)

# 如果启用了 FTZ/DAZ，定义宏 ENABLE_FTZ_DAZ=1
# 程序可在运行时据此启用 flush-to-zero 和 denormals-are-zero 模式
if(FTZ_DAZ)
  add_definitions(-DENABLE_FTZ_DAZ=1)
endif()

# 定义可执行文件 bench，入口源文件为 src/bench.cpp
add_executable(bench src/bench.cpp)
