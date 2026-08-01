#include "engine_api.h"

#if defined(TTS_HELPER_FAKE_QWEN)
#include "fake_qwen3tts_c_api.h"
#else
#include "qwen3tts_c_api.h"
#endif

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr std::int32_t kMaximumEmbeddingDimensions = 4096;

struct AudioDeleter {
	void operator()(Qwen3TtsAudio *audio) const noexcept {
		qwen3_tts_free_audio(audio);
	}
};

using AudioHandle = std::unique_ptr<Qwen3TtsAudio, AudioDeleter>;

class QwenEngine final : public EngineApi {
public:
	QwenEngine(std::string model_directory, std::int32_t threads,
			std::int32_t max_audio_tokens, float temperature)
		: model_directory_(std::move(model_directory)), threads_(threads),
		  max_audio_tokens_(max_audio_tokens), temperature_(temperature) {}

	~QwenEngine() override {
		unload();
	}

	bool load(std::string &error) override {
		if (handle_ != nullptr) {
			return true;
		}
		handle_ = qwen3_tts_create(model_directory_.c_str(), threads_);
		if (handle_ == nullptr) {
			// The pinned upstream C API deletes its temporary handle before
			// returning nullptr, so qwen3_tts_get_error() cannot retain this error.
			error = "cannot load qwen models from " + model_directory_;
			return false;
		}
		return true;
	}

	void unload() override {
		if (handle_ == nullptr) {
			return;
		}
		qwen3_tts_destroy(handle_);
		handle_ = nullptr;
	}

	bool is_loaded() const override {
		return handle_ != nullptr && qwen3_tts_is_loaded(handle_) != 0;
	}

	bool synthesize(const std::string &text, std::int32_t language_id,
			const std::vector<float> *embedding, EngineAudio &audio,
			std::string &error) override {
		if (!load(error)) {
			return false;
		}

		Qwen3TtsParams parameters;
		qwen3_tts_default_params(&parameters);
		parameters.n_threads = threads_;
		parameters.language_id = language_id;
		// Generation does not always stop, and the library's own defaults are the
		// combination that lets it run: the graph is sized from the token ceiling,
		// so a run that never emits EOS asks for all 21598 MiB of it. The ceiling
		// bounds the damage and the temperature is what stops it happening — both
		// are needed, and neither is a value with only an upper bound. The full
		// measurement record is in tools/qwen3_tts_daemon.py, which applies the
		// same two numbers through ctypes; keep the two in step.
		if (max_audio_tokens_ > 0) {
			parameters.max_audio_tokens = max_audio_tokens_;
		}
		if (temperature_ > 0.0f) {
			parameters.temperature = temperature_;
		}

		AudioHandle result(embedding != nullptr && !embedding->empty()
				? qwen3_tts_synthesize_with_embedding(
						handle_, text.c_str(), embedding->data(),
						static_cast<std::int32_t>(embedding->size()), &parameters)
				: qwen3_tts_synthesize(handle_, text.c_str(), &parameters));
		if (!result) {
			error = last_error();
			return false;
		}
		if (result->samples == nullptr || result->n_samples <= 0 ||
				result->sample_rate <= 0) {
			error = "qwen returned an empty audio buffer";
			return false;
		}
		audio.samples.assign(result->samples, result->samples + result->n_samples);
		audio.sample_rate = result->sample_rate;
		return true;
	}

	bool extract_embedding(const std::string &wav_path,
			std::vector<float> &embedding, std::string &error) override {
		if (!load(error)) {
			return false;
		}
		std::vector<float> buffer(kMaximumEmbeddingDimensions);
		const std::int32_t dimensions = qwen3_tts_extract_embedding_file(
				handle_, wav_path.c_str(), buffer.data(),
				static_cast<std::int32_t>(buffer.size()));
		if (dimensions <= 0 ||
				dimensions > static_cast<std::int32_t>(buffer.size())) {
			error = last_error();
			return false;
		}
		buffer.resize(static_cast<std::size_t>(dimensions));
		embedding = std::move(buffer);
		return true;
	}

private:
	std::string last_error() const {
		const char *message = qwen3_tts_get_error(handle_);
		if (message == nullptr || *message == '\0') {
			return "qwen engine returned no error detail";
		}
		return message;
	}

	std::string model_directory_;
	std::int32_t threads_;
	std::int32_t max_audio_tokens_;
	float temperature_;
	Qwen3Tts *handle_ = nullptr;
};

}  // namespace

std::unique_ptr<EngineApi> create_engine(
		const std::string &model_directory, std::int32_t threads,
		std::int32_t max_audio_tokens, float temperature) {
	return std::make_unique<QwenEngine>(
			model_directory, threads, max_audio_tokens, temperature);
}

const char *compiled_engine_name() {
#if defined(TTS_HELPER_FAKE_QWEN)
	return "fake-qwen";
#else
	return "qwen3-tts";
#endif
}
