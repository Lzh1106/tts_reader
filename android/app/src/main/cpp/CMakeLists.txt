# LAME（MP3 编码器）的 Android 构建配置（★v1.21.45 改动 5）
#
# 由 `tool/build_lame.ps1` 调用：把 **LAME 3.100 核心** 与我们的 JNI 薄包装
# (`lame_jni.c`) 编成一个 `liblame.so`，放进 `android/app/src/main/jniLibs/<abi>/`。
#
# ## 为什么不走 Gradle 的 externalNativeBuild
#
# 施工单要求「编译产物落在 jniLibs/<abi>/liblame.so」+「编译步骤可复现」：
# 预编译的 .so 入库 + 一个独立脚本，比让 Gradle 每次构建都编译第三方 C 代码
# 更可控（Flutter 的构建环境换 NDK 版本时不会突然编不过），也便于单独验证。
#
# ## 为什么不用 HAVE_CONFIG_H
#
# LAME 上游用 autotools 生成 `config.h`。**故意不定义** `HAVE_CONFIG_H`：
# 这样 `machine.h` 会走它自己的默认分支（不依赖 autotools 探测结果），
# Android / bionic 下能直接编过 —— 这也是多数 Android 移植的做法。
# 一旦定义了 `HAVE_CONFIG_H`（哪怕是 0），`#ifdef` 同样成立，就会去找
# 根本不存在的 config.h。

cmake_minimum_required(VERSION 3.18)
project(lamejni C)

# LAME 源码根目录（由 build_lame.ps1 用 -DLAME_SRC=... 传进来）
if(NOT DEFINED LAME_SRC OR LAME_SRC STREQUAL "")
    message(FATAL_ERROR "必须传 -DLAME_SRC=<LAME 源码根目录>（见 tool/build_lame.ps1）")
endif()
# ⚠️ Windows 上传进来的是反斜杠路径（C:\a\b），直接喂给 add_library 会被
# CMake 当成转义序列（Invalid character escape '\l'）—— 先统一成 / 分隔。
file(TO_CMAKE_PATH "${LAME_SRC}" LAME_SRC)
if(NOT EXISTS "${LAME_SRC}/libmp3lame/version.h")
    message(FATAL_ERROR "LAME_SRC 不像 LAME 源码：${LAME_SRC}")
endif()

# 只取**编码核心**：libmp3lame/*.c + mpglib/*.c
# （libmp3lame/vector/ 是 x86 SSE 优化，默认用不上；frontend/ 是命令行程序，不编）
file(GLOB LAME_CORE
        "${LAME_SRC}/libmp3lame/*.c"
        "${LAME_SRC}/mpglib/*.c")

# LAME 的 config.h：上游那套是 autotools 生成的，Android 上跑不起来 ——
# 用仓库里手写的最小版本（见 lame_config.h.in 的说明）。
configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/lame_config.h.in"
        "${CMAKE_CURRENT_BINARY_DIR}/config.h"
        COPYONLY)

add_library(lame SHARED
        ${LAME_CORE}
        "${CMAKE_CURRENT_SOURCE_DIR}/lame_jni.c")

target_include_directories(lame PRIVATE
        # config.h 在构建目录里，必须排在源码目录之前
        "${CMAKE_CURRENT_BINARY_DIR}"
        "${LAME_SRC}/include"
        "${LAME_SRC}/libmp3lame"
        "${LAME_SRC}/mpglib"
        "${CMAKE_CURRENT_SOURCE_DIR}")

# HAVE_CONFIG_H：让 LAME 源码 include 我们那份 config.h
target_compile_definitions(lame PRIVATE HAVE_CONFIG_H=1)

# log 用来打 TTS_LAME 日志；m 是数学库（LAME 的 FFT / 心理声学模型要用）
find_library(log-lib log)
target_link_libraries(lame PRIVATE ${log-lib} m)

target_compile_options(lame PRIVATE -O3 -fvisibility=hidden -DNDEBUG)
# JNI 入口必须导出（否则 -fvisibility=hidden 会把它们藏起来）
set_target_properties(lame PROPERTIES
        C_VISIBILITY_PRESET default
        POSITION_INDEPENDENT_CODE ON)
