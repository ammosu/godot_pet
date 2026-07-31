#include "engine_api.h"

#include <memory>
#include <string>

namespace {

class UnavailableEngine final : public EngineApi {
public:
	bool load(std::string &error) override {
		error = "qwen engine is not linked";
		return false;
	}

	void unload() override {}

	bool is_loaded() const override {
		return false;
	}

	bool synthesize(const std::string &, std::int32_t,
			const std::vector<float> *, EngineAudio &, std::string &error) override {
		error = "qwen engine is not linked";
		return false;
	}

	bool extract_embedding(const std::string &, std::vector<float> &,
			std::string &error) override {
		error = "qwen engine is not linked";
		return false;
	}
};

}  // namespace

std::unique_ptr<EngineApi> create_engine(const std::string &, std::int32_t) {
	return std::make_unique<UnavailableEngine>();
}

const char *compiled_engine_name() {
	return "unavailable";
}
