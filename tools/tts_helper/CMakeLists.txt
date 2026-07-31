cmake_minimum_required(VERSION 3.14)
project(godot_pet_tts_helper VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(QWEN3_TTS_SOURCE "" CACHE PATH
	"External qwen3-tts.cpp checkout pinned by fetch_sources.sh")

if(NOT QWEN3_TTS_SOURCE)
	message(FATAL_ERROR "Set QWEN3_TTS_SOURCE to the pinned external checkout")
endif()
if(NOT EXISTS "${QWEN3_TTS_SOURCE}/src/qwen3tts_c_api.h")
	message(FATAL_ERROR "QWEN3_TTS_SOURCE does not contain qwen3tts_c_api.h")
endif()
if(NOT EXISTS "${QWEN3_TTS_SOURCE}/ggml/build")
	message(FATAL_ERROR
		"Build pinned ggml at QWEN3_TTS_SOURCE/ggml/build first; "
		"tools/tts_helper/build_engine.sh does this")
endif()

# Upstream's project defines qwen3_tts as a static target. EXCLUDE_FROM_ALL
# avoids building its CLI/tests/shared wrapper when only this helper is wanted.
add_subdirectory(
	"${QWEN3_TTS_SOURCE}"
	"${CMAKE_CURRENT_BINARY_DIR}/qwen3-tts"
	EXCLUDE_FROM_ALL
)

add_executable(godot-pet-tts-helper
	main.cpp
	qwen_engine.cpp
	"${QWEN3_TTS_SOURCE}/src/qwen3tts_c_api.cpp"
)
target_include_directories(godot-pet-tts-helper PRIVATE
	"${CMAKE_CURRENT_SOURCE_DIR}"
	"${QWEN3_TTS_SOURCE}/src"
)
target_link_libraries(godot-pet-tts-helper PRIVATE qwen3_tts)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
	target_compile_options(godot-pet-tts-helper PRIVATE
		-Wall
		-Wextra
		-Wpedantic
	)
endif()
