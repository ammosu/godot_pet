#include "fake_qwen3tts_c_api.h"

#include <chrono>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

struct Qwen3Tts {
	std::string error;
	std::string trace;
};

namespace {

Qwen3TtsAudio *make_audio(float voice_bias, std::int32_t sample_rate = 24000,
		const char *free_trace_path = nullptr) {
	const std::vector<float> samples = {
		0.0f, 0.25f + voice_bias, -0.25f, 0.75f, -0.75f, 1.5f, -1.5f,
	};
	auto *audio = new Qwen3TtsAudio;
	auto *buffer = new float[samples.size()];
	std::memcpy(buffer, samples.data(), samples.size() * sizeof(float));
	audio->samples = buffer;
	audio->n_samples = static_cast<std::int32_t>(samples.size());
	audio->sample_rate = sample_rate;
	audio->free_trace_path = free_trace_path;
	return audio;
}

void append_trace(const Qwen3Tts *tts, const char *line) {
	std::ofstream(tts->trace, std::ios::app) << line << '\n';
}

}  // namespace

extern "C" {

void qwen3_tts_default_params(Qwen3TtsParams *params) {
	params->max_audio_tokens = 4096;
	params->temperature = 0.9f;
	params->top_p = 1.0f;
	params->top_k = 50;
	params->n_threads = 4;
	params->repetition_penalty = 1.05f;
	params->language_id = 2050;
}

Qwen3Tts *qwen3_tts_create(const char *model_dir, std::int32_t) {
	if (model_dir == nullptr || std::string(model_dir).find("fail-load") != std::string::npos) {
		return nullptr;
	}
	auto *tts = new Qwen3Tts;
	tts->trace = (std::filesystem::path(model_dir) / "fake_engine_trace").string();
	std::ofstream(tts->trace, std::ios::app) << "load\n";
	return tts;
}

int qwen3_tts_is_loaded(const Qwen3Tts *tts) {
	return tts == nullptr ? 0 : 1;
}

Qwen3TtsAudio *qwen3_tts_synthesize(
		Qwen3Tts *tts, const char *text, const Qwen3TtsParams *params) {
	if (tts == nullptr || text == nullptr) {
		return nullptr;
	}
	if (std::string(text) == "FAIL") {
		tts->error = "synthetic failure";
		return nullptr;
	}
	if (std::string(text) == "THROW") {
		throw std::runtime_error("synthetic engine exception");
	}
	if (std::string(text) == "EXPECT_ZH" &&
			(params == nullptr || params->language_id != 2055)) {
		tts->error = "expected Traditional Chinese language id";
		return nullptr;
	}
	// Reports the two runaway limits back rather than checking them, so the test
	// can assert the numbers it put on the command line without this file
	// carrying a second copy of them to drift against.
	if (std::string(text) == "REPORT_LIMITS") {
		tts->error = params == nullptr
				? "no params"
				: "max_audio_tokens=" + std::to_string(params->max_audio_tokens) +
						" temperature=" + std::to_string(params->temperature);
		return nullptr;
	}
	if (std::string(text) == "SLOW") {
		append_trace(tts, "slow-start");
		std::this_thread::sleep_for(std::chrono::milliseconds(75));
		append_trace(tts, "slow-end");
	}
	if (std::string(text) == "BAD_RATE") {
		return make_audio(0.0f, std::numeric_limits<std::int32_t>::max());
	}
	if (std::string(text) == "BAD_AUDIO") {
		Qwen3TtsAudio *audio = make_audio(0.0f, 24000, tts->trace.c_str());
		audio->n_samples = 0;
		return audio;
	}
	if (std::string(text) == "BAD_AUDIO_NAN" ||
			std::string(text) == "BAD_AUDIO_INF") {
		Qwen3TtsAudio *audio = make_audio(0.0f, 24000, tts->trace.c_str());
		const_cast<float *>(audio->samples)[2] =
				std::string(text) == "BAD_AUDIO_NAN"
				? std::numeric_limits<float>::quiet_NaN()
				: std::numeric_limits<float>::infinity();
		return audio;
	}
	return make_audio(0.0f);
}

Qwen3TtsAudio *qwen3_tts_synthesize_with_embedding(
		Qwen3Tts *tts, const char *text, const float *embedding,
		std::int32_t embedding_size, const Qwen3TtsParams *) {
	if (tts == nullptr || text == nullptr || embedding == nullptr || embedding_size <= 0) {
		return nullptr;
	}
	return make_audio(0.1f);
}

std::int32_t qwen3_tts_extract_embedding_file(
		Qwen3Tts *tts, const char *reference_audio_path,
		float *embedding_out, std::int32_t max_size) {
	if (tts == nullptr || embedding_out == nullptr || max_size < 4) {
		return -1;
	}
	embedding_out[0] = 0.125f;
	embedding_out[1] = -0.25f;
	embedding_out[2] = 0.5f;
	embedding_out[3] = 1.0f;
	if (reference_audio_path != nullptr &&
			std::string(reference_audio_path).find("BAD_EMBEDDING_NAN") !=
					std::string::npos) {
		embedding_out[2] = std::numeric_limits<float>::quiet_NaN();
	}
	return 4;
}

void qwen3_tts_free_audio(Qwen3TtsAudio *audio) {
	if (audio == nullptr) {
		return;
	}
	if (audio->free_trace_path != nullptr) {
		std::ofstream(audio->free_trace_path, std::ios::app) << "audio-free\n";
	}
	delete[] audio->samples;
	delete audio;
}

void qwen3_tts_destroy(Qwen3Tts *tts) {
	if (tts != nullptr) {
		std::ofstream(tts->trace, std::ios::app) << "unload\n";
	}
	delete tts;
}

const char *qwen3_tts_get_error(const Qwen3Tts *tts) {
	return tts == nullptr ? "" : tts->error.c_str();
}

}  // extern "C"
