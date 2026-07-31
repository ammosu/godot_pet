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

std::unique_ptr<EngineApi> create_engine(
		const std::string &model_directory, std::int32_t threads);
const char *compiled_engine_name();

#endif
