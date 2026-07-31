#ifndef GODOT_PET_FAKE_QWEN3TTS_C_API_H
#define GODOT_PET_FAKE_QWEN3TTS_C_API_H

#include <cstdint>

extern "C" {

typedef struct Qwen3Tts Qwen3Tts;

typedef struct Qwen3TtsParams {
	std::int32_t max_audio_tokens;
	float temperature;
	float top_p;
	std::int32_t top_k;
	std::int32_t n_threads;
	float repetition_penalty;
	std::int32_t language_id;
} Qwen3TtsParams;

typedef struct Qwen3TtsAudio {
	const float *samples;
	std::int32_t n_samples;
	std::int32_t sample_rate;
	const char *free_trace_path;
} Qwen3TtsAudio;

void qwen3_tts_default_params(Qwen3TtsParams *params);
Qwen3Tts *qwen3_tts_create(const char *model_dir, std::int32_t n_threads);
int qwen3_tts_is_loaded(const Qwen3Tts *tts);
Qwen3TtsAudio *qwen3_tts_synthesize(
		Qwen3Tts *tts, const char *text, const Qwen3TtsParams *params);
Qwen3TtsAudio *qwen3_tts_synthesize_with_embedding(
		Qwen3Tts *tts, const char *text, const float *embedding,
		std::int32_t embedding_size, const Qwen3TtsParams *params);
std::int32_t qwen3_tts_extract_embedding_file(
		Qwen3Tts *tts, const char *reference_audio_path,
		float *embedding_out, std::int32_t max_size);
void qwen3_tts_free_audio(Qwen3TtsAudio *audio);
void qwen3_tts_destroy(Qwen3Tts *tts);
const char *qwen3_tts_get_error(const Qwen3Tts *tts);

}

#endif
