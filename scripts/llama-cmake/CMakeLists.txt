# Standalone CMake project that builds llama.cpp as a static library from the
# sources vendored inside the whisper.cpp submodule's examples/talk-llama/
# directory (whisper.cpp ships a full llama.cpp snapshot there for its own
# "talk-llama" example — see examples/talk-llama/README.md). Building from
# that copy, rather than adding a second llama.cpp submodule, means there is
# only ever one ggml build in this project: a second submodule would vendor
# its own ggml and produce duplicate-symbol link errors against the ggml
# already built for Whisper (see docs/text-rewrite-notes.md).
#
# This project does NOT build ggml itself — it links against the ggml static
# libraries already built by scripts/build-whisper.sh (whisper.cpp/build),
# passed in via LLAMA_GGML_BUILD_DIR. Run build-whisper.sh first.
cmake_minimum_required(VERSION 3.14)
project(whisperdictation_llama CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED TALK_LLAMA_DIR)
    message(FATAL_ERROR "TALK_LLAMA_DIR must point at whisper.cpp/examples/talk-llama")
endif()
if(NOT DEFINED WHISPER_CPP_DIR)
    message(FATAL_ERROR "WHISPER_CPP_DIR must point at the whisper.cpp submodule root (already built via build-whisper.sh, so whisper.cpp/build/ggml exists)")
endif()
set(WHISPER_CPP_BUILD_DIR "${WHISPER_CPP_DIR}/build")

file(GLOB LLAMA_MODEL_SOURCES "${TALK_LLAMA_DIR}/models/*.cpp")

add_library(whisperdictation_llama STATIC
    ${TALK_LLAMA_DIR}/llama.cpp
    ${TALK_LLAMA_DIR}/llama-adapter.cpp
    ${TALK_LLAMA_DIR}/llama-arch.cpp
    ${TALK_LLAMA_DIR}/llama-batch.cpp
    ${TALK_LLAMA_DIR}/llama-chat.cpp
    ${TALK_LLAMA_DIR}/llama-context.cpp
    ${TALK_LLAMA_DIR}/llama-cparams.cpp
    ${TALK_LLAMA_DIR}/llama-grammar.cpp
    ${TALK_LLAMA_DIR}/llama-graph.cpp
    ${TALK_LLAMA_DIR}/llama-hparams.cpp
    ${TALK_LLAMA_DIR}/llama-impl.cpp
    ${TALK_LLAMA_DIR}/llama-io.cpp
    ${TALK_LLAMA_DIR}/llama-kv-cache.cpp
    ${TALK_LLAMA_DIR}/llama-kv-cache-iswa.cpp
    ${TALK_LLAMA_DIR}/llama-kv-cache-dsa.cpp
    ${TALK_LLAMA_DIR}/llama-memory-recurrent.cpp
    ${TALK_LLAMA_DIR}/llama-memory-hybrid.cpp
    ${TALK_LLAMA_DIR}/llama-memory-hybrid-iswa.cpp
    ${TALK_LLAMA_DIR}/llama-memory.cpp
    ${TALK_LLAMA_DIR}/llama-mmap.cpp
    ${TALK_LLAMA_DIR}/llama-model-loader.cpp
    ${TALK_LLAMA_DIR}/llama-model-saver.cpp
    ${TALK_LLAMA_DIR}/llama-model.cpp
    ${TALK_LLAMA_DIR}/llama-quant.cpp
    ${TALK_LLAMA_DIR}/llama-sampler.cpp
    ${TALK_LLAMA_DIR}/llama-vocab.cpp
    ${TALK_LLAMA_DIR}/unicode.cpp
    ${TALK_LLAMA_DIR}/unicode-data.cpp
    ${LLAMA_MODEL_SOURCES}
)

target_include_directories(whisperdictation_llama PRIVATE
    ${TALK_LLAMA_DIR}
    ${TALK_LLAMA_DIR}/models
    ${WHISPER_CPP_DIR}/ggml/include
)

# Link against the ggml static libs whisper.cpp already built (Metal-enabled —
# see build-whisper.sh), so llama.cpp inference gets the same GPU acceleration
# Whisper transcription does, with no second ggml build.
find_library(GGML_LIB ggml PATHS ${WHISPER_CPP_BUILD_DIR}/ggml/src REQUIRED NO_DEFAULT_PATH)
find_library(GGML_BASE_LIB ggml-base PATHS ${WHISPER_CPP_BUILD_DIR}/ggml/src REQUIRED NO_DEFAULT_PATH)
find_library(GGML_CPU_LIB ggml-cpu PATHS ${WHISPER_CPP_BUILD_DIR}/ggml/src REQUIRED NO_DEFAULT_PATH)

target_link_libraries(whisperdictation_llama PRIVATE ${GGML_LIB} ${GGML_BASE_LIB} ${GGML_CPU_LIB})
