#ifndef GODOT_PET_TTS_HELPER_ENGINE_API_H
#define GODOT_PET_TTS_HELPER_ENGINE_API_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct EngineAudio {
	std::vector<float> samples;
	std::int32_t sample_rate = 24000;
};

class EngineApi {
public:
	virtual ~EngineApi() = default;

	virtual bool load(std::string &error) = 0;
	virtual void unload() = 0;
	virtual bool is_loaded() const = 0;
	virtual bool synthesize(const std::string &text, std::int32_t language_id,
			const std::vector<float> *embedding, EngineAudio &audio,
			std::string &error) = 0;
	virtual bool extract_embedding(const std::string &wav_path,
			std::vector<float> &embedding, std::string &error) = 0;
};

// `max_audio_tokens` and `temperature` carry the runaway-generation limits, and
// a non-positive value for either means "leave the library's own default" — the
// same contract tools/qwen3_tts_daemon.py offers, because the voice falls back
// from this helper to that one silently and the two must sound the same.
std::unique_ptr<EngineApi> create_engine(
		const std::string &model_directory, std::int32_t threads,
		std::int32_t max_audio_tokens, float temperature);
const char *compiled_engine_name();

#endif
